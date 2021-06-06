module LandingPage.Handlers (showLandingPage) where

import Control.Exception.Safe
import Control.Monad (when)
import qualified Data.Text as Text
import qualified Data.Time as Time
import qualified Database.SQLite.Simple as SQLite
import Layout (ActiveNavLink (..), layout)
import Lucid
import qualified Routes.Data as Auth
import qualified WelcomeMessage.Card
import WelcomeMessage.WelcomeMessage (getAllWelcomeMsgsFromDb,WelcomeMsg (..), WelcomeMsgId (..))
import Prelude hiding (id)

showLandingPage ::
  SQLite.Connection ->
  Auth.Authenticated ->
  IO (Html ())
showLandingPage conn auth = do
  let userIsAdmin = case auth of
        Auth.IsAdmin _ -> True
        _ -> False
  msgs <-
    handleAny (\e -> throwString $ "error getting welcome messages: " <> show e) $
      getAllWelcomeMsgsFromDb conn
  zone <- Time.getCurrentTimeZone
  return $
    layout "Willkommen" (Just Welcome) $
      div_ [class_ "container"] $ do
        div_ [class_ "row row-cols-1 g-4"] $ do
          div_ [class_ "col"] $
            p_ [class_ "m-0 alert alert-primary"] $ do
              "Alle Dateien (inklusive Bilderarchiv) des Lions Club Achern befinden sich auf "
              a_ [href_ "https://1drv.ms/f/s!As3H-io1fRdFcZnEJ0BXdpeV9Lw"] "Microsoft OneDrive"
          div_ [class_ "col d-flex flex-wrap-reverse align-items-center"] $ do
            h1_ [class_ "h3 m-0 me-2 mb-1"] "Interne Neuigkeiten"
            when userIsAdmin $
              a_ [class_ "btn btn-primary mb-1", href_ "/neu", role_ "button"] "Neue Nachricht"
          div_ [class_ "col"] $ do
            div_ [class_ "row row-cols-1 g-5"] $ do
              mapM_
                ( \(WelcomeMsg (WelcomeMsgId id) content datetime) ->
                    let editHref = WelcomeMessage.Card.EditHref $ Text.pack $ "/editieren/" <> show id
                        deleteHref = WelcomeMessage.Card.DeleteHref $ Text.pack $ "/loeschen/" <> show id
                        zoned = Time.utcToZonedTime zone datetime
                     in (WelcomeMessage.Card.render editHref deleteHref (content, zoned) userIsAdmin)
                )
                msgs
