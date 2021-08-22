module WelcomeMessage
  ( saveNewMessage,
    showMessageEditForm,
    showFeed,
    showAddMessageForm,
    WelcomeMsgId (..),
    WelcomeMsg (..),
    handleEditMessage,
    showDeleteConfirmation,
    handleDeleteMessage,
  )
where

import qualified App
import Control.Exception.Safe
import Control.Monad (when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Reader.Class (MonadReader, asks)
import qualified Data.Map.Strict as Map
import Data.String.Interpolate (i)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Time as Time
import qualified Database.SQLite.Simple as SQLite
import Form (FormFieldState (..), notEmpty, processField, validDate)
import Layout (ActiveNavLink (..), LayoutStub (..), describedBy_, infoBox, success)
import Locale (german)
import Lucid
import qualified Network.Wai as Wai
import qualified User.Session
import Wai (parseParams)
import Prelude hiding (id)

newtype WelcomeMsgId = WelcomeMsgId Int deriving (Show)

data WelcomeMsg = WelcomeMsg WelcomeMsgId Text Time.UTCTime deriving (Show)

-- | Returns the MOST RECENT welcome message, if there is one
getWelcomeMsgFromDb ::
  ( MonadIO m,
    App.HasDb env,
    MonadThrow m,
    MonadReader env m
  ) =>
  WelcomeMsgId ->
  m (Maybe WelcomeMsg)
getWelcomeMsgFromDb (WelcomeMsgId id) = do
  conn <- asks App.getDb
  rows <- liftIO $ SQLite.query conn "SELECT id, content, date FROM welcome_text WHERE id = ?" [id]
  case rows of
    [(mid, msg, createdAt) :: (Int, Text, Time.UTCTime)] ->
      return . Just $ WelcomeMsg (WelcomeMsgId mid) msg createdAt
    [] -> return Nothing
    other -> return . throwString $ "unexpected result from DB for welcome message" <> show other

-- | Returns all welcome messages in chronological order
getAllWelcomeMsgsFromDb ::
  ( MonadIO m,
    App.HasDb env,
    MonadThrow m,
    MonadReader env m
  ) =>
  m [WelcomeMsg]
getAllWelcomeMsgsFromDb = do
  conn <- asks App.getDb
  rows <- liftIO $ SQLite.query_ conn "SELECT id, content, date FROM welcome_text ORDER BY date DESC"
  case rows of
    (msgs :: [(Int, Text, Time.UTCTime)]) ->
      return $ map (\(id, msg, createdAt) -> WelcomeMsg (WelcomeMsgId id) msg createdAt) msgs

data FormState = FormState
  { welcomeMsgStateDate :: FormFieldState Time.UTCTime,
    welcomeMsgStateMessage :: FormFieldState Text
  }
  deriving (Show)

data FormInput = FormInput
  { welcomeMsgInputDate :: Text,
    welcomeMsgInputMessage :: Text
  }
  deriving (Show)

emptyState :: FormState
emptyState = FormState NotValidated NotValidated

makeMessage :: FormInput -> Either FormState (Text, Time.UTCTime)
makeMessage FormInput {..} =
  case FormState (validDate welcomeMsgInputDate) (notEmpty welcomeMsgInputMessage) of
    FormState (Valid date) (Valid message) ->
      Right (message, date)
    state -> Left state

form :: FormInput -> FormState -> Text -> Html ()
form FormInput {..} FormState {..} formAction = do
  form_ [method_ "post", class_ "row g-4", action_ formAction] $ do
    div_ [class_ "col-12"] $ do
      let (className, errMsg) = processField welcomeMsgStateDate
      label_ [class_ "form-label", for_ "date"] "Datum"
      input_
        [ class_ className,
          type_ "text",
          name_ "date",
          pattern_ "\\d{2}.\\d{2}.\\d{4} \\d{2}:\\d{2}",
          value_ welcomeMsgInputDate,
          id_ "date",
          required_ "required",
          describedBy_ "invalidDateFeedback"
        ]
      maybe mempty (div_ [class_ "invalid-feedback", id_ "invalidDateFeedback"] . toHtml) errMsg
    div_ [class_ "col-12"] $ do
      let (className, errMsg) = processField welcomeMsgStateMessage
      label_ [class_ "form-label", for_ "message"] "Nachricht"
      textarea_
        [ class_ className,
          type_ "textfield",
          name_ "message",
          id_ "message",
          required_ "required",
          autofocus_,
          rows_ "10",
          cols_ "10",
          describedBy_ "invalidMessageFeedback"
        ]
        (toHtml welcomeMsgInputMessage)
      maybe mempty (div_ [class_ "invalid-feedback", id_ "invalidMessageFeedback"] . toHtml) errMsg
    button_ [class_ "btn btn-primary", type_ "submit"] "Speichern"

type ShowEditBtn = Bool

newtype EditHref = EditHref Text

newtype DeleteHref = DeleteHref Text

renderSingleMessage :: EditHref -> DeleteHref -> (Text, Time.ZonedTime) -> ShowEditBtn -> Html ()
renderSingleMessage (EditHref editHref) (DeleteHref deleteHref) (msg, date) canEdit =
  article_ [class_ ""] $ do
    let formatted = Time.formatTime german "%A, %d. %B %Y" date
     in do
          h2_ [class_ "h4"] $ toHtml formatted
          p_ [class_ "", style_ "white-space: pre-wrap"] $ toHtml msg
          when canEdit $
            div_ [class_ "d-flex"] $ do
              a_ [class_ "link-primary me-3", href_ editHref] "Ändern"
              a_ [class_ "link-danger me-3", href_ deleteHref] "Löschen"

renderFeed :: Time.TimeZone -> Bool -> [WelcomeMsg] -> LayoutStub
renderFeed zone userIsAdmin msgs =
  LayoutStub "Willkommen" (Just Welcome) $
    div_ [class_ "container"] $ do
      div_ [class_ "row row-cols-1 g-4"] $ do
        div_ [class_ "col"] $ do
          when userIsAdmin $
            a_ [class_ "btn btn-sm btn-primary mb-2", href_ "/neu", role_ "button"] "Neue Nachricht"
          h1_ [class_ "h3 m-0 mb-1"] "Interne Neuigkeiten"
        div_ [class_ "col"] $ do
          infoBox $ do
            "Alle Dateien (inklusive Bilderarchiv) des Lions Club Achern befinden sich auf "
            a_ [href_ "https://1drv.ms/f/s!As3H-io1fRdFcZnEJ0BXdpeV9Lw"] "Microsoft OneDrive"
        div_ [class_ "col"] $ do
          when userIsAdmin $ do
            infoBox $ do
              "Mit diesem Link "
              a_ [href_ "https://1drv.ms/f/s!As3H-io1fRdFcUPc-Dz3SC08Wno"] "(Microsoft OneDrive)"
              [i|
              können die Dateien im geteilten Ordner "Lions Dateien" bearbeitet
              werden. Dieser Link ist nur für Administratoren gedacht und wird
              auch nur Administratoren angezeigt. Zum Bearbeiten ist jedoch ein
              Microsoft Account notwendig!
              |]
        div_ [class_ "col"] $ do
          div_ [class_ "row row-cols-1 g-5"] $ do
            mapM_
              ( \(WelcomeMsg (WelcomeMsgId id) content datetime) ->
                  let editHref = EditHref $ Text.pack $ "/editieren/" <> show id
                      deleteHref = DeleteHref $ Text.pack $ "/loeschen/" <> show id
                      zoned = Time.utcToZonedTime zone datetime
                   in (renderSingleMessage editHref deleteHref (content, zoned) userIsAdmin)
              )
              msgs

updateWelcomeMsg ::
  ( MonadIO m,
    App.HasDb env,
    MonadThrow m,
    MonadReader env m
  ) =>
  WelcomeMsgId ->
  Text ->
  Time.UTCTime ->
  m ()
updateWelcomeMsg (WelcomeMsgId id) newMsg newDate = do
  conn <- asks App.getDb
  liftIO $ SQLite.execute conn "UPDATE welcome_text SET content = ?, date = ? WHERE id = ?" (newMsg, newDate, id)

saveNewWelcomeMsg ::
  ( MonadIO m,
    App.HasDb env,
    MonadThrow m,
    MonadReader env m
  ) =>
  Text ->
  Time.UTCTime ->
  m ()
saveNewWelcomeMsg msg date = do
  conn <- asks App.getDb
  liftIO $ SQLite.execute conn "INSERT INTO welcome_text (content, date) VALUES (?, ?)" (msg, date)

deleteMessage ::
  ( MonadIO m,
    App.HasDb env,
    MonadThrow m,
    MonadReader env m
  ) =>
  WelcomeMsgId ->
  m ()
deleteMessage (WelcomeMsgId id) = do
  conn <- asks App.getDb
  liftIO $ SQLite.execute conn "DELETE FROM welcome_text WHERE id = ?" [id]

-- TODO: Something like this should probably exist for all pages. Maybe make
-- the title smaller, so it's almost more like breadcrums?
pageLayout :: Text -> Html () -> LayoutStub
pageLayout title content =
  LayoutStub title (Just Welcome) $
    div_ [class_ "container p-2"] $ do
      h1_ [class_ "h4 mb-3"] $ toHtml title
      content

editPageLayout, createPageLayout, deletePageLayout :: Html () -> LayoutStub
editPageLayout = pageLayout "Nachricht Editieren"
createPageLayout = pageLayout "Nachricht Erstellen"
deletePageLayout = pageLayout "Nachricht Löschen"

saveNewMessage ::
  ( MonadIO m,
    App.HasDb env,
    MonadThrow m,
    MonadReader env m
  ) =>
  Wai.Request ->
  User.Session.Admin ->
  m LayoutStub
saveNewMessage req _ = do
  params <- liftIO $ parseParams req
  let input =
        FormInput
          (Map.findWithDefault "" "date" params)
          (Map.findWithDefault "" "message" params)

  case makeMessage input of
    Left state ->
      return . createPageLayout $ form input state "/neu"
    Right (message, date) -> do
      saveNewWelcomeMsg message date
      return . createPageLayout $ success "Nachricht erfolgreich erstellt"

handleEditMessage ::
  ( MonadIO m,
    App.HasDb env,
    MonadThrow m,
    MonadReader env m
  ) =>
  Wai.Request ->
  WelcomeMsgId ->
  User.Session.Admin ->
  m LayoutStub
handleEditMessage req mid@(WelcomeMsgId msgid) _ = do
  params <- liftIO $ parseParams req
  let input =
        FormInput
          (Map.findWithDefault "" "date" params)
          (Map.findWithDefault "" "message" params)

  case makeMessage input of
    Left state ->
      return . editPageLayout $ form input state [i|/editieren/#{msgid}|]
    Right (message, date) -> do
      updateWelcomeMsg mid message date
      return . editPageLayout $ success "Nachricht erfolgreich editiert"

showDeleteConfirmation ::
  ( MonadIO m,
    App.HasDb env,
    MonadThrow m,
    MonadReader env m
  ) =>
  WelcomeMsgId ->
  User.Session.Admin ->
  m LayoutStub
showDeleteConfirmation mid@(WelcomeMsgId msgid) _ = do
  getWelcomeMsgFromDb mid >>= \case
    Nothing -> throwString [i|delete request, but no message with ID: #{msgid}|]
    Just (WelcomeMsg _ content _) -> do
      return . deletePageLayout $ do
        p_ [] "Nachricht wirklich löschen?"
        p_ [class_ "border p-2 mb-4", role_ "alert"] $ toHtml content
        form_ [action_ [i|/loeschen/#{msgid}|], method_ "post", class_ ""] $
          button_ [class_ "btn btn-danger", type_ "submit"] "Ja, Nachricht löschen!"

handleDeleteMessage ::
  ( MonadIO m,
    App.HasDb env,
    MonadThrow m,
    MonadReader env m
  ) =>
  WelcomeMsgId ->
  User.Session.Admin ->
  m LayoutStub
handleDeleteMessage msgid _ = do
  deleteMessage msgid
  return . deletePageLayout $ success "Nachricht erfolgreich gelöscht"

showAddMessageForm ::
  (MonadIO m) =>
  User.Session.Admin ->
  m LayoutStub
showAddMessageForm _ = do
  now <- liftIO $ Time.getCurrentTime
  let formatted = Text.pack . Time.formatTime german "%d.%m.%Y %R" $ now
  return . createPageLayout $ form (FormInput formatted "") emptyState "/neu"

showMessageEditForm ::
  ( MonadIO m,
    App.HasDb env,
    MonadThrow m,
    MonadReader env m
  ) =>
  WelcomeMsgId ->
  User.Session.Admin ->
  m LayoutStub
showMessageEditForm mid@(WelcomeMsgId msgid) _ = do
  getWelcomeMsgFromDb mid >>= \case
    Nothing -> throwString $ "edit message but no welcome message found for id: " <> show msgid
    Just (WelcomeMsg _ content date) -> do
      let formatted = Text.pack . Time.formatTime german "%d.%m.%Y %R" $ date
      return . editPageLayout $ form (FormInput formatted content) emptyState [i|/editieren/#{msgid}|]

showFeed ::
  ( MonadIO m,
    App.HasDb env,
    MonadThrow m,
    MonadReader env m
  ) =>
  User.Session.Authenticated ->
  m LayoutStub
showFeed auth = do
  msgs <- getAllWelcomeMsgsFromDb
  zone <- liftIO $ Time.getCurrentTimeZone
  return $ renderFeed zone (User.Session.isAdmin' auth) msgs
