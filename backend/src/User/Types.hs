module User.Types
  ( UserProfile (..),
    UserProfileCreate (..),
    UserEmail (..),
    Session (..),
    showEmail,
    UserId (..),
    Role (..),
    parseRole,
  )
where

import Data.Aeson
  ( FromJSON (..),
    ToJSON,
    Value (..),
    defaultOptions,
    genericToEncoding,
    toEncoding,
    toJSON,
  )
import qualified Data.Aeson as Aeson
import Data.List.NonEmpty (NonEmpty)
import Data.String.Interpolate (i)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import GHC.Generics
import Text.Email.Validate (EmailAddress, emailAddress, toByteString)

newtype UserEmail = UserEmail EmailAddress deriving (Show, Eq)

instance ToJSON UserEmail where
  toJSON (UserEmail email) = String $ showEmail email

instance FromJSON UserEmail where
  parseJSON (Aeson.String s) =
    case emailAddress (encodeUtf8 s) of
      Just addr -> return $ UserEmail addr
      Nothing -> fail [i|couldn't parse email: #{s}|]
  parseJSON _ = fail "wrong type for email"

data UserProfileCreate = UserProfileCreate
  { userCreateEmail :: UserEmail,
    userCreateFirstName :: Maybe Text,
    userCreateLastName :: Maybe Text,
    userCreateAddress :: Maybe Text,
    userCreateMobilePhoneNr :: Maybe Text,
    userCreateLandlineNr :: Maybe Text,
    userCreateBirthday :: Maybe Text,
    userCreateFirstNamePartner :: Maybe Text,
    userCreateLastNamePartner :: Maybe Text,
    userCreateBirthdayPartner :: Maybe Text,
    userCreateRoles :: NonEmpty Role
  }
  deriving (Show, Generic)

instance ToJSON UserProfileCreate where
  toEncoding = genericToEncoding defaultOptions

data UserProfile = UserProfile
  { userEmail :: UserEmail,
    userFirstName :: Maybe Text,
    userLastName :: Maybe Text,
    userAddress :: Maybe Text,
    userMobilePhoneNr :: Maybe Text,
    userLandlineNr :: Maybe Text,
    userBirthday :: Maybe Text,
    userFirstNamePartner :: Maybe Text,
    userLastNamePartner :: Maybe Text,
    userBirthdayPartner :: Maybe Text,
    userId :: UserId,
    userRoles :: NonEmpty Role
  }
  deriving (Show, Generic)

instance ToJSON UserProfile where
  toEncoding = genericToEncoding defaultOptions

-- There's some overlap with the Session type defined in Session.Session. That
-- type represents the session data retrieved from the DB based on the ID
-- stored client side. This Session here, on the other hand, is the user info
-- associated with that session. I think it's fine to separate them, but
-- Session has a confusing name. It's closer to a special type to marshal and
-- unmarshal to and from a database. This Sessino is closer to the actual
-- (user) session, at least in spirit.
-- Also, this type is called Session because it's expected to be used as a
--
-- qualified import, as in User.Session
data Session = Session
  { sessionUserId :: UserId,
    sessionUserRoles :: [Role]
  }
  deriving (Show, Eq)

data Role = Admin | User | Board | President | Passive deriving (Eq, Generic)

instance ToJSON Role where
  toEncoding = genericToEncoding defaultOptions

instance Show Role where
  show Admin = "admin"
  show User = "user"
  show Passive = "passive"
  show Board = "board"
  show President = "president"

parseRole :: Text -> Either Text Role
parseRole "admin" = Right Admin
parseRole "user" = Right User
parseRole "board" = Right Board
parseRole "president" = Right President
parseRole "passive" = Right Passive
parseRole v = Left $ "unknown role: " <> Text.pack (show v)

newtype UserId = UserId Int
  deriving (Show)
  deriving (Generic)
  deriving (Eq)

instance ToJSON UserId where
  toEncoding = genericToEncoding defaultOptions

instance FromJSON UserId

showEmail :: EmailAddress -> Text
showEmail = decodeUtf8 . toByteString
