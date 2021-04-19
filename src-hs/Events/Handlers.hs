{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Events.Handlers
  ( showAllEvents,
    showCreateEvent,
    showEvent,
    showDeleteEventConfirmation,
    handleDeleteEvent,
    handleCreateEvent,
    handleUpdateEvent,
    showEditEventForm,
    replyToEvent,
  )
where

import Capability.Reader (HasReader (..), ask)
import Control.Exception.Safe
import Control.Monad (when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Foldable (find)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Ord (Down (..))
import qualified Data.Text as Text
import Data.Text.Encoding (encodeUtf8)
import qualified Data.Time as Time
import qualified Database.SQLite.Simple as SQLite
import Events.DB
  ( createEvent,
    deleteEvent,
    deleteReply,
    getAll,
    getEvent,
    updateEvent,
    upsertReply,
  )
import Events.Domain (Event (..), EventCreate (..), EventId (..), Reply (..))
import qualified Events.EventCard
import qualified Events.EventForm as EventForm
import qualified Events.SingleEvent
import GHC.Exts (sortWith)
import Katip
import Layout (ActiveNavLink (..), layout)
import Locale (german)
import Lucid
import Network.HTTP.Types (status303, status404)
import qualified Network.Wai as Wai
import qualified Routes.Data as Auth
import Text.Read (readEither)
import User.DB (getUser)
import User.Domain (UserProfile (..))
import Wai (parseParams)

showAllEvents ::
  ( MonadIO m,
    HasReader "dbConn" SQLite.Connection m,
    KatipContext m
  ) =>
  Auth.Authenticated ->
  m (Html ())
showAllEvents auth = do
  let (userIsAdmin, Auth.UserSession {..}) = case auth of
        Auth.IsAdmin (Auth.AdminUser session) -> (True, session)
        Auth.IsUser session -> (False, session)
  conn <- ask @"dbConn"
  events <- map (addOwnReply userSessionUserId) . sortByDateDesc . Map.toList <$> liftIO (getAll conn)
  return . layout "Veranstaltungen" (Just Events) $
    div_ [class_ "container p-2"] $ do
      when userIsAdmin $
        a_ [class_ "mb-4 btn btn-primary", href_ "/veranstaltungen/neu", role_ "button"] "Neue Veranstaltung"
      div_ [class_ "row row-cols-1 row-cols-lg-2 g-5"] $
        mapM_ (div_ [class_ "col"] . Events.EventCard.render) events
  where
    addOwnReply userid (eventid, e@Event {..}) = (eventid, e, find ((==) userid . replyUserId) eventReplies)
    sortByDateDesc = sortWith (Down . (\(_, Event {..}) -> eventDate))

replyToEvent ::
  ( MonadIO m,
    MonadThrow m,
    HasReader "dbConn" SQLite.Connection m,
    KatipContext m
  ) =>
  Wai.Request ->
  (Wai.Response -> m a) ->
  EventId ->
  Auth.Authenticated ->
  m a
replyToEvent req send eventid@(EventId i) auth = do
  let (_, Auth.UserSession {..}) = case auth of
        Auth.IsAdmin (Auth.AdminUser session) -> (True, session)
        Auth.IsUser session -> (False, session)
  conn <- ask @"dbConn"
  UserProfile {..} <-
    getUser conn userSessionUserId >>= \case
      Nothing -> throwString "no user for userid from session"
      Just v -> return v
  params <- liftIO $ parseParams req
  coming <-
    maybe (throwString "no 'reply' param") parseComing $
      Map.lookup "reply" params
  numberOfGuests <-
    maybe (throwString "no 'numberOfGuests' param") parseNumGuests $
      Map.lookup "numberOfGuests" params
  case coming of
    Nothing -> deleteReply conn eventid userSessionUserId
    Just yesno -> upsertReply conn eventid (Reply yesno userEmail userSessionUserId numberOfGuests)
  send $ Wai.responseLBS status303 [("Location", encodeUtf8 $ "/veranstaltungen/" <> Text.pack (show i))] mempty
  where
    parseComing "coming" = return $ Just True
    parseComing "notcoming" = return $ Just False
    parseComing "noreply" = return Nothing
    parseComing s = throwString . Text.unpack $ "unknown 'coming' value: " <> s

    parseNumGuests "" = return 0
    parseNumGuests s =
      case readEither (Text.unpack s) of
        Left e -> throwString . Text.unpack $ "couldn't parse '" <> s <> "' number of guests as number: " <> Text.pack (show e)
        Right i' -> return i'

showEvent ::
  ( MonadIO m,
    HasReader "dbConn" SQLite.Connection m,
    KatipContext m
  ) =>
  EventId ->
  (Wai.Response -> m a) ->
  Auth.Authenticated ->
  m a
showEvent eventid@(EventId i) send auth = do
  let (userIsAdmin, Auth.UserSession {..}) = case auth of
        Auth.IsAdmin (Auth.AdminUser session) -> (True, session)
        Auth.IsUser session -> (False, session)
  conn <- ask @"dbConn"
  katipAddContext (sl "eventid" i) $ do
    maybeevent <- liftIO (getEvent conn eventid)
    case maybeevent of
      Nothing -> do
        logLocM WarningS "no event found"
        -- TODO: This is duplicated from Main
        send
          . Wai.responseLBS status404 [("Content-Type", "text/html; charset=UTF-8")]
          . renderBS
          . layout "Nicht gefunden" Nothing
          $ div_ [class_ "container p-3 d-flex justify-content-center"] $
            div_ [class_ "row col-6"] $ do
              p_ [class_ "alert alert-secondary", role_ "alert"] "Nicht gefunden"
      Just e@Event {..} -> do
        let ownReply = find ((==) userSessionUserId . replyUserId) eventReplies
        send $
          Wai.responseLBS status404 [("Location", "/veranstaltungen")]
            . renderBS
            . layout
              eventTitle
              (Just Events)
            $ Events.SingleEvent.render (Events.SingleEvent.ShowAdminTools userIsAdmin) ownReply eventid e

showCreateEvent ::
  ( MonadIO m,
    HasReader "dbConn" SQLite.Connection m,
    KatipContext m
  ) =>
  Auth.AdminUser ->
  m (Html ())
showCreateEvent _ = do
  return . layout "Neue Veranstaltung" (Just Events) $
    div_ [class_ "container p-2"] $ do
      h1_ [class_ "h4 mb-3"] "Neue Veranstaltung erstellen"
      EventForm.render "Speichern" "/veranstaltungen/neu" EventForm.emptyForm EventForm.emptyState

handleDeleteEvent ::
  ( MonadIO m,
    MonadThrow m,
    KatipContext m,
    HasReader "dbConn" SQLite.Connection m
  ) =>
  EventId ->
  Auth.AdminUser ->
  m (Html ())
handleDeleteEvent eventid _ = do
  conn <- ask @"dbConn"
  maybeEvent <- liftIO $ getEvent conn eventid
  case maybeEvent of
    Nothing -> return . layout "Fehler" (Just Events) $
      div_ [class_ "container p-3 d-flex justify-content-center"] $
        div_ [class_ "row col-6"] $ do
          p_ [class_ "alert alert-secondary", role_ "alert"] "Kein Nutzer mit dieser ID gefunden"
    Just event -> do
      deleteEvent conn eventid
      return $
        layout "Veranstaltung" (Just Events) $
          div_ [class_ "container p-3 d-flex justify-content-center"] $
            div_ [class_ "row col-6"] $ do
              p_ [class_ "alert alert-success", role_ "alert"] . toHtml $
                "Veranstaltung " <> show (eventTitle event) <> " erfolgreich gelöscht"

showDeleteEventConfirmation ::
  ( MonadIO m,
    MonadThrow m,
    KatipContext m,
    HasReader "dbConn" SQLite.Connection m
  ) =>
  EventId ->
  Auth.AdminUser ->
  m (Html ())
showDeleteEventConfirmation eid@(EventId eventid) _ = do
  -- TODO: Duplicated
  conn <- ask @"dbConn"
  liftIO (getEvent conn eid) >>= \case
    Nothing -> throwString $ "delete event but no event for id: " <> show eventid
    Just event -> do
      return . layout "Veranstaltung Löschen" (Just Events) $
        div_ [class_ "container p-3 d-flex justify-content-center"] $
          div_ [class_ "row col-6"] $ do
            p_ [class_ "alert alert-danger mb-4", role_ "alert"] $
              toHtml ("Veranstaltung " <> eventTitle event <> " wirklich löschen?")
            form_
              [ action_ . Text.pack $ "/veranstaltungen/" <> show eventid <> "/loeschen",
                method_ "post",
                class_ "d-flex justify-content-center"
              ]
              $ button_ [class_ "btn btn-primary", type_ "submit"] "Ja, Veranstaltung löschen!"

handleCreateEvent ::
  ( MonadIO m,
    MonadThrow m,
    KatipContext m,
    HasReader "dbConn" SQLite.Connection m
  ) =>
  Wai.Request ->
  Auth.AdminUser ->
  m (Html ())
handleCreateEvent req _ = do
  conn <- ask @"dbConn"
  params <- liftIO $ parseParams req
  let input =
        EventForm.FormInput
          (Map.findWithDefault "" "eventTitleInput" params)
          (Map.findWithDefault "" "eventDateInput" params)
          (Map.findWithDefault "" "eventLocationInput" params)
          (Map.findWithDefault "" "eventDescriptionInput" params)
          (isJust $ Map.lookup "eventFamAllowedInput" params)
  case EventForm.makeEvent input of
    Left state -> do
      return . layout "Neue Veranstaltung" (Just Events) $
        div_ [class_ "container p-2"] $ do
          h1_ [class_ "h4 mb-3"] "Neue Veranstaltung erstellen"
          EventForm.render "Speichern" "/veranstaltungen/neu" input state
    Right newEvent@EventCreate {..} -> do
      liftIO $ createEvent conn newEvent
      return . layout "Neue Veranstaltung" (Just Events) $
        div_ [class_ "container p-2"] $ do
          h1_ [class_ "h4 mb-3"] "Neue Veranstaltung erstellen"
          p_ [class_ "alert alert-success", role_ "alert"] . toHtml $
            "Neue Veranstaltung" <> show eventCreateTitle <> " erfolgreich erstellt!"

showEditEventForm ::
  ( MonadIO m,
    MonadThrow m,
    KatipContext m,
    HasReader "dbConn" SQLite.Connection m
  ) =>
  EventId ->
  Auth.AdminUser ->
  m (Html ())
showEditEventForm eid@(EventId eventid) _ = do
  conn <- ask @"dbConn"
  liftIO (getEvent conn eid) >>= \case
    Nothing -> throwString $ "edit event but no event for id: " <> show eventid
    Just Event {..} ->
      let input =
            EventForm.FormInput
              eventTitle
              (renderDateForInput eventDate)
              eventLocation
              eventDescription
              eventFamilyAllowed
       in return . layout "Veranstaltung Editieren" (Just Events) $
            div_ [class_ "container p-2"] $ do
              h1_ [class_ "h4 mb-3"] "Veranstaltung editieren"
              EventForm.render "Speichern" (Text.pack $ "/veranstaltungen/" <> show eventid <> "/editieren") input EventForm.emptyState
  where
    renderDateForInput = Text.pack . Time.formatTime german "%d.%m.%Y %R"

handleUpdateEvent ::
  ( MonadIO m,
    MonadThrow m,
    KatipContext m,
    HasReader "dbConn" SQLite.Connection m
  ) =>
  Wai.Request ->
  EventId ->
  Auth.AdminUser ->
  m (Html ())
handleUpdateEvent req eid@(EventId eventid) _ = do
  conn <- ask @"dbConn"
  params <- liftIO $ parseParams req
  let input =
        EventForm.FormInput
          (Map.findWithDefault "" "eventTitleInput" params)
          (Map.findWithDefault "" "eventDateInput" params)
          (Map.findWithDefault "" "eventLocationInput" params)
          (Map.findWithDefault "" "eventDescriptionInput" params)
          (isJust $ Map.lookup "eventFamAllowedInput" params)
  case EventForm.makeEvent input of
    Left state ->
      return $
        layout "Veranstaltung Editieren" (Just Events) $
          div_ [class_ "container p-3 d-flex justify-content-center"] $
            EventForm.render
              "Speichern"
              (Text.pack $ "/veranstaltungen/" <> show eventid <> "/editieren")
              input
              state
    Right event@EventCreate {..} -> do
      liftIO $ updateEvent conn eid event
      katipAddContext (sl "event" event) $ do
        logLocM DebugS "editing event"
        return $
          layout "Veranstaltung Editieren" (Just Events) $
            div_ [class_ "container p-3 d-flex justify-content-center"] $
              div_ [class_ "row col-6"] $ do
                p_ [class_ "alert alert-success", role_ "alert"] . toHtml $
                  "Veranstaltung " <> eventCreateTitle <> " erfolgreich editiert"
