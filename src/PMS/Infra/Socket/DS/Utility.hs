{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}

module PMS.Infra.Socket.DS.Utility where

import Control.Lens
import System.Exit
import System.IO
import System.Log.FastLogger
import qualified Control.Exception.Safe as E
import Control.Monad.IO.Class
import Control.Monad.Except
import Control.Monad.Reader
import qualified Control.Concurrent.STM as STM
import Network.Socket
import qualified Data.ByteString as B
import Network.Socket.ByteString
import qualified Data.ByteString.Base16 as B16
import qualified Data.ByteString.Char8 as C8
import Control.Monad 

import qualified PMS.Domain.Model.DM.Type as DM
import qualified PMS.Domain.Model.DS.Utility as DM
import PMS.Infra.Socket.DM.Type
import PMS.Infra.Socket.DM.Constant

-- |
--
runApp :: DM.DomainData -> AppData -> TimedFastLogger -> AppContext a -> IO (Either DM.ErrorData a)
runApp domDat appDat logger ctx =
  DM.runFastLoggerT domDat logger
    $ runExceptT
    $ flip runReaderT domDat
    $ runReaderT ctx appDat


-- |
--
liftIOE :: IO a -> AppContext a
liftIOE f = liftIO (go f) >>= liftEither
  where
    go :: IO b -> IO (Either String b)
    go x = E.catchAny (Right <$> x) errHdl

    errHdl :: E.SomeException -> IO (Either String a)
    errHdl = return . Left . show

---------------------------------------------------------------------------------
-- |
--
toolsCallResponse :: STM.TQueue DM.McpResponse
                  -> DM.JsonRpcRequest
                  -> ExitCode
                  -> String
                  -> String
                  -> IO ()
toolsCallResponse resQ jsonRpc code outStr errStr = do
  let content = [ DM.McpToolsCallResponseResultContent "text" outStr
                , DM.McpToolsCallResponseResultContent "text" errStr
                ]
      result = DM.McpToolsCallResponseResult {
                  DM._contentMcpToolsCallResponseResult = content
                , DM._isErrorMcpToolsCallResponseResult = (ExitSuccess /= code)
                }
      resDat = DM.McpToolsCallResponseData jsonRpc result
      res = DM.McpToolsCallResponse resDat

  STM.atomically $ STM.writeTQueue resQ res

-- |
--
errorToolsCallResponse :: DM.JsonRpcRequest -> String -> AppContext ()
errorToolsCallResponse jsonRpc errStr = do
  let content = [ DM.McpToolsCallResponseResultContent "text" errStr ]
      result = DM.McpToolsCallResponseResult {
                  DM._contentMcpToolsCallResponseResult = content
                , DM._isErrorMcpToolsCallResponseResult = True
                }
      resDat = DM.McpToolsCallResponseData jsonRpc result
      res = DM.McpToolsCallResponse resDat

  resQ <- view DM.responseQueueDomainData <$> lift ask
  liftIOE $ STM.atomically $ STM.writeTQueue resQ res

-- |
--   
bytesToHex :: B.ByteString -> String
bytesToHex = C8.unpack . B16.encode


-- |
--   
readSizeSocket :: Socket -> Int -> IO B.ByteString
readSizeSocket sock size = do
  msg <- recv sock size
  if B.null msg
    then E.throwString "Connection closed by remote host"
    else do
      let hexMsg = bytesToHex msg
      hPutStrLn stderr $ "[DEBUG]PMS.Infra.Socket.DS.Utility.readSocket Received " ++ show (B.length msg) ++ " bytes: " ++ hexMsg
      return msg

-- |
--   
writeSocket :: Socket -> B.ByteString -> IO ()
writeSocket sock bs = do
  hPutStrLn stderr $ "PMS.Infra.Socket.DS.Utility.writeSocket " ++ show bs
  sendAll sock bs
 
-- |
--   
createSocket :: HostName -> ServiceName -> IO Socket
createSocket host port = do
  let hint  = Just defaultHints { addrSocketType = Stream }
      justH = Just host
      justP = Just port
  
  getAddrInfo hint justH justP >>= \case
      [] -> E.throwString "No suitable address found for the given host and port."
      (serverAddr:_) -> do
          sock <- socket (addrFamily serverAddr) (addrSocketType serverAddr) (addrProtocol serverAddr)
          connect sock (addrAddress serverAddr)
          return sock
{-

-- |
--   
sendInitialTelnetOptions :: Socket -> IO ()
sendInitialTelnetOptions sock = do
    sendAll sock (iac <> wont <> telopt_echo)
    sendAll sock (iac <> wont <> telopt_suppress_ga)
    sendAll sock (iac <> wont <> telopt_naws)
    sendAll sock (iac <> wont <> telopt_ttype)
    sendAll sock (iac <> wont <> telopt_new_environ)

    sendAll sock (iac <> dont <> telopt_echo)
    sendAll sock (iac <> dont <> telopt_suppress_ga)
    sendAll sock (iac <> dont <> telopt_naws)
    sendAll sock (iac <> dont <> telopt_ttype)


-- |
--   
iac  = B.singleton 0xFF
do_  = B.singleton 0xFD
will = B.singleton 0xFB
wont = B.singleton 0xFC
dont = B.singleton 0xFE
-}

-- |
--   
respondToIAC :: Socket -> B.ByteString -> IO ()
respondToIAC sock bs = go bs
  where
    go s
      | B.length s < 3 = return ()
      | B.head s == 0xFF =
          let cmd  = B.index s 1
              opt  = B.index s 2
              rest = B.drop 3 s
              rsp  = case cmd of
                       0xFD -> iac <> wont <> B.singleton opt
                       0xFB -> iac <> dont <> B.singleton opt
                       _    -> B.empty
          in do
            let hexRsp = bytesToHex rsp
            hPutStrLn stderr $ "[DEBUG]PMS.Infra.Socket.DS.Utility.respondToIAC Sending response: " ++ hexRsp
            unless (B.null rsp) $ sendAll sock rsp
            go rest
      | otherwise = go (B.tail s)


-- |
--   
readTelnetSocket :: Socket -> IO B.ByteString
readTelnetSocket sock = do
  msg <- recv sock 4096
  if B.null msg
    then E.throwString "Connection closed by remote host"
    else do
      let hexMsg = bytesToHex msg
      hPutStrLn stderr $ "[DEBUG]PMS.Infra.Socket.DS.Utility.readTelnetSocket Received " ++ show (B.length msg) ++ " bytes: " ++ hexMsg

      if 0xFF `B.elem` msg
        then do
          respondToIAC sock msg
          readTelnetSocket sock
        else
          return msg

