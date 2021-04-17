{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module WelcomeMessage.Handlers (saveNewMessage, showMessageEditForm) where

import Capability.Reader (HasReader (..), ask)
import Control.Monad
import Control.Monad.IO.Class (MonadIO, liftIO)
import qualified Data.Map.Strict as Map
import Data.Maybe (isNothing)
import qualified Database.SQLite.Simple as SQLite
import Katip
import Lucid
import qualified Network.Wai as Wai
import qualified Routes.Data as Auth
import Wai (parseParams)
import WelcomeMessage.DB (getWelcomeMsgFromDb, saveNewWelcomeMsg)
import WelcomeMessage.Domain (WelcomeMsg (..))
import WelcomeMessage.Form (WelcomeMsgFormState (..))
import qualified WelcomeMessage.Form

saveNewMessage ::
  ( MonadIO m,
    HasReader "dbConn" SQLite.Connection m
  ) =>
  Wai.Request ->
  Auth.AdminUser ->
  m (Html ())
saveNewMessage req _ = do
  conn <- ask @"dbConn"
  params <- liftIO $ parseParams req
  case Map.lookup "message" params of
    Nothing -> return $ WelcomeMessage.Form.render (Invalid "Nachricht darf nicht leer sein") ""
    Just msg -> do
      liftIO $ saveNewWelcomeMsg conn msg
      return $ WelcomeMessage.Form.render Valid msg

showMessageEditForm ::
  ( MonadIO m,
    KatipContext m,
    HasReader "dbConn" SQLite.Connection m
  ) =>
  Auth.AdminUser ->
  m (Html ())
showMessageEditForm _ = do
  conn <- ask @"dbConn"
  msg <- liftIO $ getWelcomeMsgFromDb conn
  when (isNothing msg) $ logLocM InfoS "no welcome msg"
  return $ WelcomeMessage.Form.render NotValidated (maybe "" (\(WelcomeMsg content _) -> content) msg)
