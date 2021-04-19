{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

module PasswordReset.DB
  ( getTokenForUser,
    updatePassword,
    insertToken,
    getTokenByValue,
    deleteToken,
  )
where

import Control.Exception.Safe
import Control.Monad (forM_)
import Control.Monad.IO.Class (MonadIO, liftIO)
import qualified Crypto.BCrypt as BCrypt
import qualified Data.List.NonEmpty as NE
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import qualified Data.Time as Time
import qualified Database.SQLite.Simple as SQLite
import Database.SQLite.Simple.FromField (FromField (..), ResultError (..), fieldData, returnError)
import Database.SQLite.Simple.FromRow (FromRow)
import Database.SQLite.Simple.Ok (Ok (..))
import Database.SQLite.Simple.QQ (sql)
import Database.SQLite.Simple.ToField (ToField (..))
import Database.SQLite.Simple.ToRow (ToRow (..))
import PasswordReset.Domain (Token (..), TokenCreate (..), TokenId (..), Hashed, unhash)
import Text.Email.Validate (EmailAddress)
import qualified Text.Email.Validate as Email
import TextShow
import Time.Time (timeDaysFromNow)
import User.Domain
  ( Role (..),
    UserEmail (..),
    UserId (..),
    UserProfile (..),
    UserProfileCreate (..),
    parseRole,
  )
import Prelude hiding (id)

newtype DBToken = DBToken Token deriving (Show)

instance FromRow DBToken where
  fromRow =
    DBToken
      <$> ( Token <$> SQLite.field
              <*> SQLite.field
              <*> (TokenId <$> SQLite.field)
              <*> (UserId <$> SQLite.field)
          )

updatePassword :: (MonadIO m) => SQLite.Connection -> Hashed -> UserId -> m ()
updatePassword conn hashed (UserId userid) = do
  let newPw = unhash hashed
  liftIO $ SQLite.execute conn "update users set password_digest = ? where id = ?" (newPw, show userid)

getTokenByValue :: (MonadCatch m, MonadThrow m, MonadIO m) => SQLite.Connection -> Text -> m (Maybe Token)
getTokenByValue conn t =
  handleAny (\e -> throwString $ "error getting users: " <> show e) $
    liftIO (SQLite.query conn "select token, expires, id, userid from reset_tokens where token = ?" [t])
      >>= \case
        [] -> return Nothing
        [(DBToken token) :: DBToken] -> return $ Just token
        _ -> throwString . Text.unpack $ "returned more than one token for value: " <> t

getTokenForUser :: (MonadThrow m, MonadIO m) => SQLite.Connection -> UserId -> m (Maybe Token)
getTokenForUser conn (UserId userid) =
  liftIO (SQLite.query conn "select token, expires, id, userid from reset_tokens where userid = ?" [userid])
    >>= \case
      [] -> return Nothing
      [(DBToken token) :: DBToken] -> return $ Just token
      s -> throwString $ "returned more than one token for user: '" <> show userid <> "', got: '" <> show s <> "'"

-- Run this and generate token in transaction
deleteToken :: (MonadIO m) => SQLite.Connection -> UserId -> m ()
deleteToken conn (UserId userid) = liftIO . SQLite.execute conn "delete from reset_tokens where userid = ?" $ SQLite.Only userid

insertToken :: (MonadIO m) => SQLite.Connection -> TokenCreate -> m ()
insertToken conn TokenCreate {tokenCreateUserId = (UserId userid), ..} =
  liftIO $
    SQLite.execute
      conn
      "insert into reset_tokens (token, expires, userid) values (?,?,?)"
      (tokenCreateValue, tokenCreateExpires, userid)

-- updateToken :: (MonadIO m) => SQLite.Connection -> Token -> m ()
-- updateToken conn Token {tokenUserId = (UserId userid), ..} =
--   liftIO $
--     SQLite.execute
--       conn
--       [sql|
--         insert into reset_tokens (token, expires, userid)
--         values (?,?,?)
--         on conflict (userid, token) do update set
--           token=excluded.token,
--       |]
--       (tokenValue, tokenExpires, userid)
