{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}

module PMS.Infra.Socket.DS.Core where

import System.IO
import Control.Monad.Logger
import Control.Monad.IO.Class
import Control.Monad.Trans.Class
import Control.Lens
import Control.Monad.Reader
import qualified Control.Concurrent as CC 
import Control.Concurrent.Async
import qualified Control.Concurrent.STM as STM
import Data.Conduit
import qualified Data.Text as T
import Control.Monad.Except
import qualified Control.Exception.Safe as E
import System.Exit
import qualified Data.Text.Encoding as TE
import Data.Aeson 
import qualified Data.ByteString.Char8 as BS8
import Network.Socket
import Data.Word 
import qualified Data.ByteString as B

import qualified PMS.Domain.Model.DS.Utility as DM
import qualified PMS.Domain.Model.DM.Type as DM
import qualified PMS.Domain.Model.DM.Constant as DM

import PMS.Infra.Socket.DM.Type
import PMS.Infra.Socket.DS.Utility


-- |
--
app :: AppContext ()
app = do
  $logDebugS DM._LOGTAG "app called."
  runConduit pipeline
  where
    pipeline :: ConduitM () Void AppContext ()
    pipeline = src .| cmd2task .| sink

---------------------------------------------------------------------------------
-- |
--
src :: ConduitT () DM.SocketCommand AppContext ()
src = lift go >>= yield >> src
  where
    go :: AppContext DM.SocketCommand
    go = do
      queue <- view DM.socketQueueDomainData <$> lift ask
      dat <- liftIO $ STM.atomically $ STM.readTQueue queue
      return dat

---------------------------------------------------------------------------------
-- |
--
cmd2task :: ConduitT DM.SocketCommand (IOTask ()) AppContext ()
cmd2task = await >>= \case
  Just cmd -> flip catchError errHdl $ do
    lift (go cmd) >>= yield >> cmd2task
  Nothing -> do
    $logWarnS DM._LOGTAG "cmd2task: await returns nothing. skip."
    cmd2task

  where
    errHdl :: String -> ConduitT DM.SocketCommand (IOTask ()) AppContext ()
    errHdl msg = do
      $logWarnS DM._LOGTAG $ T.pack $ "cmd2task: exception occurred. skip. " ++ msg
      lift $ errorToolsCallResponse $ "cmd2task: exception occurred. skip. " ++ msg
      cmd2task

    go :: DM.SocketCommand -> AppContext (IOTask ())
    go (DM.SocketEchoCommand dat)    = genEchoTask dat
    go (DM.SocketOpenCommand dat)    = genSocketOpenTask dat
    go (DM.SocketCloseCommand dat)   = genSocketCloseTask dat
    go (DM.SocketReadCommand dat)    = genSocketReadTask dat
    go (DM.SocketWriteCommand dat)   = genSocketWriteTask dat
    go (DM.SocketMessageCommand dat) = genSocketMessageTask dat
    go (DM.SocketTelnetCommand dat)  = genSocketTelnetTask dat

---------------------------------------------------------------------------------
-- |
--
sink :: ConduitT (IOTask ()) Void AppContext ()
sink = await >>= \case
  Just req -> flip catchError errHdl $ do
    lift (go req) >> sink
  Nothing -> do
    $logWarnS DM._LOGTAG "sink: await returns nothing. skip."
    sink

  where
    errHdl :: String -> ConduitT (IOTask ()) Void AppContext ()
    errHdl msg = do
      $logWarnS DM._LOGTAG $ T.pack $ "sink: exception occurred. skip. " ++ msg
      sink

    go :: (IO ()) -> AppContext ()
    go task = do
      $logDebugS DM._LOGTAG "sink: start async."
      _ <- liftIOE $ async task
      $logDebugS DM._LOGTAG "sink: end async."
      return ()


---------------------------------------------------------------------------------
-- |
--
genEchoTask :: DM.SocketEchoCommandData -> AppContext (IOTask ())
genEchoTask dat = do
  resQ <- view DM.responseQueueDomainData <$> lift ask
  let val = dat^.DM.valueSocketEchoCommandData

  $logDebugS DM._LOGTAG $ T.pack $ "echoTask: echo : " ++ val
  return $ echoTask resQ dat val


-- |
--
echoTask :: STM.TQueue DM.McpResponse -> DM.SocketEchoCommandData -> String -> IOTask ()
echoTask resQ cmdDat val = flip E.catchAny errHdl $ do
  hPutStrLn stderr $ "[INFO] PMS.Infra.Socket.DS.Core.echoTask run. " ++ val

  toolsCallResponse resQ (cmdDat^.DM.jsonrpcSocketEchoCommandData) ExitSuccess val ""

  hPutStrLn stderr "[INFO] PMS.Infra.Socket.DS.Core.echoTask end."

  where
    errHdl :: E.SomeException -> IO ()
    errHdl e = toolsCallResponse resQ (cmdDat^.DM.jsonrpcSocketEchoCommandData) (ExitFailure 1) "" (show e)

-- |
--
genSocketOpenTask :: DM.SocketOpenCommandData -> AppContext (IOTask ())
genSocketOpenTask cmdDat = do
  let argsBS   = DM.unRawJsonByteString $ cmdDat^.DM.argumentsSocketOpenCommandData

  resQ <- view DM.responseQueueDomainData <$> lift ask
  socketMVar <- view socketAppData <$> ask
  argsDat <- liftEither $ eitherDecode $ argsBS
  let host = argsDat^.hostSocketToolParams
      port = argsDat^.portSocketToolParams

  $logDebugS DM._LOGTAG $ T.pack $ "genSocketOpenTask: cmd. " ++ host ++ ":" ++ port
 
  return $ socketOpenTask cmdDat resQ socketMVar host port


-- |
--   
socketOpenTask :: DM.SocketOpenCommandData
              -> STM.TQueue DM.McpResponse
              -> STM.TMVar (Maybe Socket)
              -> String
              -> String
              -> IOTask ()
socketOpenTask cmdDat resQ socketVar host port = do
  hPutStrLn stderr $ "[INFO] PMS.Infra.Socket.DS.Core.socketOpenTask start. "

  STM.atomically (STM.takeTMVar socketVar) >>= \case
    Just p -> do
      STM.atomically $ STM.putTMVar socketVar $ Just p
      hPutStrLn stderr "[ERROR] PMS.Infrastructure.DS.Core.socketOpenTask: socket is already connected."
      toolsCallResponse resQ (cmdDat^.DM.jsonrpcSocketOpenCommandData) (ExitFailure 1) "" "socket is already running."
    Nothing -> flip E.catchAny errHdl $ do
      sock <- createSocket host port
      STM.atomically $ STM.putTMVar socketVar (Just sock)
      toolsCallResponse resQ (cmdDat^.DM.jsonrpcSocketOpenCommandData) ExitSuccess ("socket connected to " ++ host ++ ":" ++ port) ""

  hPutStrLn stderr "[INFO] PMS.Infra.Socket.DS.Core.socketOpenTask end."

  where
    errHdl :: E.SomeException -> IO ()
    errHdl e = do
      STM.atomically $ STM.putTMVar socketVar Nothing
      hPutStrLn stderr $ "[ERROR] PMS.Infra.Socket.DS.Core.socketRunTask: exception occurred. " ++ show e
      toolsCallResponse resQ (cmdDat^.DM.jsonrpcSocketOpenCommandData) (ExitFailure 1) "" (show e)

-- |
--
genSocketCloseTask :: DM.SocketCloseCommandData -> AppContext (IOTask ())
genSocketCloseTask dat = do
  $logDebugS DM._LOGTAG $ T.pack $ "genSocketCloseTask called. "
  socketTMVar <- view socketAppData <$> ask
  resQ <- view DM.responseQueueDomainData <$> lift ask
  return $ socketCloseTask dat resQ socketTMVar

-- |
--
socketCloseTask :: DM.SocketCloseCommandData
                  -> STM.TQueue DM.McpResponse
                  -> STM.TMVar (Maybe Socket)
                  -> IOTask ()
socketCloseTask cmdDat resQ socketTMVar = flip E.catchAny errHdl $ do
  hPutStrLn stderr $ "[INFO] PMS.Infra.Socket.DS.Core.socketCloseTask run. "
  let jsonRpc = cmdDat^.DM.jsonrpcSocketCloseCommandData

  STM.atomically (STM.swapTMVar socketTMVar Nothing) >>= \case
    Nothing -> do
      hPutStrLn stderr "[ERROR] PMS.Infra.Socket.DS.Core.socketCloseTask: socket is not started."
      toolsCallResponse resQ jsonRpc (ExitFailure 1) "" "socket is not started."
    Just sock -> do
      close sock
      toolsCallResponse resQ jsonRpc ExitSuccess "" "socket is teminated."
      hPutStrLn stderr $ "[INFO] PMS.Infra.Socket.DS.Core.socketCloseTask closeSocket : "

  hPutStrLn stderr "[INFO] PMS.Infra.Socket.DS.Core.socketCloseTask end."

  where
    -- |
    --
    errHdl :: E.SomeException -> IO ()
    errHdl e = toolsCallResponse resQ (cmdDat^.DM.jsonrpcSocketCloseCommandData) (ExitFailure 1) "" (show e)


-- |
--
genSocketReadTask :: DM.SocketReadCommandData -> AppContext (IOTask ())
genSocketReadTask cmdData = do
  let argsBS = DM.unRawJsonByteString $ cmdData^.DM.argumentsSocketReadCommandData
      tout = 30 * 1000 * 1000
  resQ <- view DM.responseQueueDomainData <$> lift ask
  socketTMVar <- view socketAppData <$> ask
  argsDat <- liftEither $ eitherDecode $ argsBS
  let size = argsDat^.sizeSocketIntToolParams

  $logDebugS DM._LOGTAG $ T.pack $ "genSocketReadTask: args. " ++ show size
  return $ socketReadTask cmdData resQ socketTMVar size tout

-- |
--
socketReadTask :: DM.SocketReadCommandData
                -> STM.TQueue DM.McpResponse
                -> STM.TMVar (Maybe Socket)
                -> Int       -- read size.
                -> Int       -- timeout microsec
                -> IOTask ()
socketReadTask cmdDat resQ socketTMVar size tout = flip E.catchAny errHdl $ do
  hPutStrLn stderr $ "[INFO] PMS.Infra.Socket.DS.Core.socketReadTask run. " ++ show size
    
  STM.atomically (STM.readTMVar socketTMVar) >>= \case
    Nothing -> do
      hPutStrLn stderr "[ERROR] PMS.Infra.Socket.DS.Core.socketReadTask: socket is not started."
      toolsCallResponse resQ jsonRpc (ExitFailure 1) "" "socket is not started."
    Just p -> go p

  hPutStrLn stderr "[INFO] PMS.Infra.Socket.DS.Core.socketReadTask end."

  where
    jsonRpc :: DM.JsonRpcRequest
    jsonRpc = cmdDat^.DM.jsonrpcSocketReadCommandData

    errHdl :: E.SomeException -> IO ()
    errHdl e = toolsCallResponse resQ jsonRpc (ExitFailure 1) "" (show e)

    go :: Socket -> IO ()
    go sock =
      race (readSizeSocket sock size) (CC.threadDelay tout) >>= \case
        Left res -> toolsCallResponse resQ jsonRpc ExitSuccess (bytesToHex res) ""
        Right _  -> toolsCallResponse resQ jsonRpc (ExitFailure 1) "" "timeout occurred."


-- |
--
genSocketWriteTask :: DM.SocketWriteCommandData -> AppContext (IOTask ())
genSocketWriteTask cmdData = do
  let argsBS = DM.unRawJsonByteString $ cmdData^.DM.argumentsSocketWriteCommandData
  resQ <- view DM.responseQueueDomainData <$> lift ask
  socketTMVar <- view socketAppData <$> ask
  argsDat <- liftEither $ eitherDecode $ argsBS
  let args = argsDat^.dataSocketWord8ArrayToolParams

  $logDebugS DM._LOGTAG $ T.pack $ "genSocketWriteTask: args. " ++ show args
  return $ socketWriteTask cmdData resQ socketTMVar args

-- |
--
socketWriteTask :: DM.SocketWriteCommandData
                -> STM.TQueue DM.McpResponse
                -> STM.TMVar (Maybe Socket)
                -> [Word8]
                -> IOTask ()
socketWriteTask cmdDat resQ socketTMVar args = flip E.catchAny errHdl $ do
  hPutStrLn stderr $ "[INFO] PMS.Infra.Socket.DS.Core.socketWriteTask run. " ++ show args
    
  STM.atomically (STM.readTMVar socketTMVar) >>= \case
    Nothing -> do
      hPutStrLn stderr "[ERROR] PMS.Infra.Socket.DS.Core.socketWriteTask: socket is not started."
      toolsCallResponse resQ jsonRpc (ExitFailure 1) "" "socket is not started."
    Just p -> go p

  hPutStrLn stderr "[INFO] PMS.Infra.Socket.DS.Core.socketWriteTask end."

  where
    jsonRpc :: DM.JsonRpcRequest
    jsonRpc = cmdDat^.DM.jsonrpcSocketWriteCommandData

    errHdl :: E.SomeException -> IO ()
    errHdl e = toolsCallResponse resQ jsonRpc (ExitFailure 1) "" (show e)

    go :: Socket -> IO ()
    go sock = do
      let bsDat = B.pack args

      hPutStrLn stderr $ "[INFO] PMS.Infra.Socket.DS.Core.socketWriteTask writeSocket (hex): " ++ bytesToHex bsDat

      writeSocket sock bsDat

      toolsCallResponse resQ jsonRpc ExitSuccess ("write data to socket. "++ bytesToHex bsDat) ""


-- |
--
genSocketMessageTask :: DM.SocketMessageCommandData -> AppContext (IOTask ())
genSocketMessageTask cmdData = do
  let argsBS = DM.unRawJsonByteString $ cmdData^.DM.argumentsSocketMessageCommandData
      tout = DM._TIMEOUT_MICROSEC
  prompts <- view DM.promptsDomainData <$> lift ask
  resQ <- view DM.responseQueueDomainData <$> lift ask
  socketTMVar <- view socketAppData <$> ask
  lockTMVar <- view lockAppData <$> ask
  argsDat <- liftEither $ eitherDecode $ argsBS
  let args = argsDat^.argumentsSocketStringToolParams

  $logDebugS DM._LOGTAG $ T.pack $ "genSocketMessageTask: args. " ++ args
  return $ socketMessageTask cmdData resQ socketTMVar lockTMVar args prompts tout

-- |
--
socketMessageTask :: DM.SocketMessageCommandData
                -> STM.TQueue DM.McpResponse
                -> STM.TMVar (Maybe Socket)
                -> STM.TMVar ()
                -> String  -- arguments line
                -> [String]  -- prompt list
                -> Int       -- timeout microsec
                -> IOTask ()
socketMessageTask cmdDat resQ socketTMVar lockTMVar args prompts tout = flip E.catchAny errHdl $ do
  hPutStrLn stderr $ "[INFO] PMS.Infra.Socket.DS.Core.socketMessageTask run. " ++ args
    
  STM.atomically (STM.readTMVar socketTMVar) >>= \case
    Nothing -> do
      hPutStrLn stderr "[ERROR] PMS.Infra.Socket.DS.Core.socketMessageTask: socket is not started."
      toolsCallResponse resQ jsonRpc (ExitFailure 1) "" "socket is not started."
    Just p -> go p

  hPutStrLn stderr "[INFO] PMS.Infra.Socket.DS.Core.socketMessageTask end."

  where
    jsonRpc :: DM.JsonRpcRequest
    jsonRpc = cmdDat^.DM.jsonrpcSocketMessageCommandData

    errHdl :: E.SomeException -> IO ()
    errHdl e = toolsCallResponse resQ jsonRpc (ExitFailure 1) "" (show e)

    go :: Socket -> IO ()
    go sock = do

      msg <- DM.validateMessage args
      let cmd = TE.encodeUtf8 $ T.pack $ msg ++ DM._CRLF

      hPutStrLn stderr $ "[INFO] PMS.Infra.Socket.DS.Core.socketMessageTask writeSocket : " ++ BS8.unpack cmd

      writeSocket sock cmd

      race (DM.expect lockTMVar (readTelnetSocket sock) prompts) (CC.threadDelay tout) >>= \case
        Left res -> toolsCallResponse resQ jsonRpc ExitSuccess (maybe "Nothing" id res) ""
        Right _  -> toolsCallResponse resQ jsonRpc (ExitFailure 1) "" "timeout occurred."



-- |
--
genSocketTelnetTask :: DM.SocketTelnetCommandData -> AppContext (IOTask ())
genSocketTelnetTask cmdDat = do
  let argsBS   = DM.unRawJsonByteString $ cmdDat^.DM.argumentsSocketTelnetCommandData
      tout     = DM._TIMEOUT_MICROSEC

  prompts <- view DM.promptsDomainData <$> lift ask
  resQ <- view DM.responseQueueDomainData <$> lift ask
  socketMVar <- view socketAppData <$> ask
  lockTMVar <- view lockAppData <$> ask

  argsDat <- liftEither $ eitherDecode $ argsBS
  let host = argsDat^.hostSocketToolParams
      port = argsDat^.portSocketToolParams
      addPrompts = ["login:"]

  $logDebugS DM._LOGTAG $ T.pack $ "genSocketTelnetTask: cmd. " ++ host ++ ":" ++ port
 
  return $ socketTelnetTask cmdDat resQ socketMVar lockTMVar host port (prompts++addPrompts) tout


-- |
--   
socketTelnetTask :: DM.SocketTelnetCommandData
              -> STM.TQueue DM.McpResponse
              -> STM.TMVar (Maybe Socket)
              -> STM.TMVar ()
              -> String
              -> String
              -> [String]
              -> Int
              -> IOTask ()
socketTelnetTask cmdDat resQ socketVar lockTMVar host port prompts tout = do
  hPutStrLn stderr $ "[INFO] PMS.Infra.Socket.DS.Core.socketTelnetTask start. "

  STM.atomically (STM.takeTMVar socketVar) >>= \case
    Just p -> do
      STM.atomically $ STM.putTMVar socketVar $ Just p
      hPutStrLn stderr "[ERROR] PMS.Infrastructure.DS.Core.socketTelnetTask: socket is already connected."
      toolsCallResponse resQ (cmdDat^.DM.jsonrpcSocketTelnetCommandData) (ExitFailure 1) "" "socket is already running."
    Nothing -> flip E.catchAny errHdl $ do
      sock <- createSocket host port
      STM.atomically $ STM.putTMVar socketVar (Just sock)

  STM.atomically (STM.readTMVar socketVar) >>= \case
    Just p -> race (DM.expect lockTMVar (readTelnetSocket p) prompts) (CC.threadDelay tout) >>= \case
      Left res -> toolsCallResponse resQ (cmdDat^.DM.jsonrpcSocketTelnetCommandData) ExitSuccess (maybe "Nothing" id res) ""
      Right _  -> toolsCallResponse resQ (cmdDat^.DM.jsonrpcSocketTelnetCommandData) (ExitFailure 1) "" "timeout occurred."
    Nothing -> do
      hPutStrLn stderr "[ERROR] PMS.Infrastructure.DS.Core.socketTelnetTask: unexpected. socket not found."
      toolsCallResponse resQ (cmdDat^.DM.jsonrpcSocketTelnetCommandData) (ExitFailure 1) "" "unexpected. socket not found."

  hPutStrLn stderr "[INFO] PMS.Infra.Socket.DS.Core.socketTelnetTask end."

  where
    errHdl :: E.SomeException -> IO ()
    errHdl e = do
      STM.atomically $ STM.putTMVar socketVar Nothing
      hPutStrLn stderr $ "[ERROR] PMS.Infra.Socket.DS.Core.socketTelnetTask: exception occurred. " ++ show e
      toolsCallResponse resQ (cmdDat^.DM.jsonrpcSocketTelnetCommandData) (ExitFailure 1) "" (show e)


