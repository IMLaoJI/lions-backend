module User.Email (Email (..), User.Email.show) where

import Data.Aeson
  ( FromJSON (..),
    ToJSON,
    Value (..),
    toJSON,
  )
import qualified Data.Aeson as Aeson
import Data.String.Interpolate (i)
import Data.Text (Text)
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Text.Email.Validate (EmailAddress, emailAddress, toByteString)

newtype Email = Email EmailAddress deriving (Show, Eq, Ord)

instance ToJSON Email where
  toJSON (Email email) = String $ User.Email.show email

instance FromJSON Email where
  parseJSON (Aeson.String s) =
    case emailAddress (encodeUtf8 s) of
      Just addr -> return $ Email addr
      Nothing -> fail [i|couldn't parse email: #{s}|]
  parseJSON _ = fail "wrong type for email"

show :: EmailAddress -> Text
show = decodeUtf8 . toByteString
