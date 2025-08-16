{-# LANGUAGE TemplateHaskell #-}

module PMS.Infra.Socket.DM.Type where

import Control.Monad.Logger
import Control.Monad.Reader
import Control.Monad.Except
import Control.Lens
import Data.Default
import Data.Aeson.TH
import qualified Control.Concurrent.STM as STM
import Network.Socket
import Data.Word 

import qualified PMS.Domain.Model.DM.Type as DM
import qualified PMS.Domain.Model.DM.TH as DM

-- |
--
data AppData = AppData {
               _socketAppData :: STM.TMVar (Maybe Socket)
             , _lockAppData :: STM.TMVar ()
             }

makeLenses ''AppData

defaultAppData :: IO AppData
defaultAppData = do
  mgrVar <- STM.newTMVarIO Nothing
  lock    <- STM.newTMVarIO ()
  return AppData {
           _socketAppData = mgrVar
         , _lockAppData = lock
         }

-- |
--
type AppContext = ReaderT AppData (ReaderT DM.DomainData (ExceptT DM.ErrorData (LoggingT IO)))

-- |
--
type IOTask = IO


--------------------------------------------------------------------------------------------
-- |
--
data SocketStringToolParams =
  SocketStringToolParams {
    _argumentsSocketStringToolParams :: String
  } deriving (Show, Read, Eq)

$(deriveJSON defaultOptions {fieldLabelModifier = DM.dropDataName "SocketStringToolParams", omitNothingFields = True} ''SocketStringToolParams)
makeLenses ''SocketStringToolParams

instance Default SocketStringToolParams where
  def = SocketStringToolParams {
        _argumentsSocketStringToolParams = def
      }

-- |
--
data SocketIntToolParams =
  SocketIntToolParams {
    _sizeSocketIntToolParams :: Int
  } deriving (Show, Read, Eq)

$(deriveJSON defaultOptions {fieldLabelModifier = DM.dropDataName "SocketIntToolParams", omitNothingFields = True} ''SocketIntToolParams)
makeLenses ''SocketIntToolParams

instance Default SocketIntToolParams where
  def = SocketIntToolParams {
        _sizeSocketIntToolParams = def
      }


-- |
--
data SocketWord8ArrayToolParams =
  SocketWord8ArrayToolParams {
    _dataSocketWord8ArrayToolParams :: [Word8]
  } deriving (Show, Read, Eq)

$(deriveJSON defaultOptions {fieldLabelModifier = DM.dropDataName "SocketWord8ArrayToolParams", omitNothingFields = True} ''SocketWord8ArrayToolParams)
makeLenses ''SocketWord8ArrayToolParams

instance Default SocketWord8ArrayToolParams where
  def = SocketWord8ArrayToolParams {
        _dataSocketWord8ArrayToolParams = def
      }


-- |
--
data SocketCommandToolParams =
  SocketCommandToolParams {
    _commandSocketCommandToolParams   :: String
  , _argumentsSocketCommandToolParams :: Maybe [String]
  } deriving (Show, Read, Eq)

$(deriveJSON defaultOptions {fieldLabelModifier = DM.dropDataName "SocketCommandToolParams", omitNothingFields = True} ''SocketCommandToolParams)
makeLenses ''SocketCommandToolParams

instance Default SocketCommandToolParams where
  def = SocketCommandToolParams {
        _commandSocketCommandToolParams   = def
      , _argumentsSocketCommandToolParams = def
      }


-- |
--
data SocketToolParams =
  SocketToolParams {
    _hostSocketToolParams :: String
  , _portSocketToolParams :: String
  } deriving (Show, Read, Eq)

$(deriveJSON defaultOptions {fieldLabelModifier = DM.dropDataName "SocketToolParams", omitNothingFields = True} ''SocketToolParams)
makeLenses ''SocketToolParams

instance Default SocketToolParams where
  def = SocketToolParams {
        _hostSocketToolParams   = def
      , _portSocketToolParams = def
      }

-- |
--
data SocketStringArrayToolParams =
  SocketStringArrayToolParams {
    _argumentsSocketStringArrayToolParams :: [String]
  } deriving (Show, Read, Eq)

$(deriveJSON defaultOptions {fieldLabelModifier = DM.dropDataName "SocketStringArrayToolParams", omitNothingFields = True} ''SocketStringArrayToolParams)
makeLenses ''SocketStringArrayToolParams

instance Default SocketStringArrayToolParams where
  def = SocketStringArrayToolParams {
        _argumentsSocketStringArrayToolParams = def
      }
