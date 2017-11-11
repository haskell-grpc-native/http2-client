
module Network.HTTP2.Client.Dispatch where

import           Control.Exception (throwIO)
import           Data.ByteString (ByteString)
import           Data.IORef (IORef, newIORef, readIORef)
import           GHC.Exception (Exception)
import           Network.HPACK as HPACK
import           Network.HTTP2 as HTTP2

import           Network.HTTP2.Client.Channels

type DispatchChan = Chan (FrameHeader, Either HTTP2Error FramePayload)
-- type DispatchChan = FramesChan HTTP2Error

-- | A fallback handler for frames.
type FallBackFrameHandler = (FrameHeader, FramePayload) -> IO ()

-- | Default FallBackFrameHandler that ignores frames.
ignoreFallbackHandler :: FallBackFrameHandler
ignoreFallbackHandler = const $ pure ()

-- | An exception thrown when the server sends a GoAwayFrame.
data RemoteSentGoAwayFrame = RemoteSentGoAwayFrame !StreamId !ErrorCodeId !ByteString
  deriving Show
instance Exception RemoteSentGoAwayFrame

-- | A Handler for exceptional circumstances.
type GoAwayHandler = RemoteSentGoAwayFrame -> IO ()

-- | Default GoAwayHandler throws a 'RemoteSentGoAwayFrame' in the current
-- thread.
--
-- A probably sharper handler if you want to abruptly stop any operation is to
-- get the 'ThreadId' of the main client thread and using
-- 'Control.Exception.Base.throwTo'.
--
-- There's an inherent race condition when receiving a GoAway frame because the
-- server will likely close the connection which will lead to TCP errors as
-- well.
defaultGoAwayHandler :: GoAwayHandler
defaultGoAwayHandler = throwIO

data Dispatch = Dispatch {
    _dispatchWriteChan   :: !DispatchChan
  , _dispatchMaxStreamId :: !(IORef StreamId)
  }

newDispatchIO :: IO Dispatch
newDispatchIO = Dispatch <$> newChan <*> newIORef 0

newDispatchReadChanIO :: Dispatch -> IO DispatchChan
newDispatchReadChanIO = dupChan . _dispatchWriteChan

readMaxReceivedStreamIdIO :: Dispatch -> IO StreamId
readMaxReceivedStreamIdIO = readIORef . _dispatchMaxStreamId

-- | Couples client and server settings together.
data ConnectionSettings = ConnectionSettings {
    _clientSettings :: !Settings
  , _serverSettings :: !Settings
  }

defaultConnectionSettings :: ConnectionSettings
defaultConnectionSettings =
    ConnectionSettings defaultSettings defaultSettings

data DispatchControl = DispatchControl {
    _dispatchControlConnectionSettings  :: !(IORef ConnectionSettings)
  , _dispatchControlHpackEncoder        :: !HpackEncoderContext
  , _dispatchControlAckPing             :: !(ByteString -> IO ())
  , _dispatchControlAckSettings         :: !(IO ())
  , _dispatchControlOnGoAway            :: !GoAwayHandler
  , _dispatchControlOnFallback          :: !FallBackFrameHandler
  }

-- | Helper to carry around the HPACK encoder for outgoing header blocks..
data HpackEncoderContext = HpackEncoderContext {
    _encodeHeaders    :: HeaderList -> IO HeaderBlockFragment
  , _applySettings    :: Int -> IO ()
  }

data DispatchHPACK e = DispatchHPACK {
    _dispatchHPACKWriteHeadersChan      :: !HeadersChan
  , _dispatchHPACKWritePushPromisesChan :: !(PushPromisesChan e)
  , _dispatchHPACKDynamicTable          :: !DynamicTable
  }

newDispatchHPACKIO :: Int -> IO (DispatchHPACK e)
newDispatchHPACKIO decoderBufSize =
    DispatchHPACK <$> newChan <*> newChan <*> newDecoder
  where
    newDecoder = newDynamicTableForDecoding
        HPACK.defaultDynamicTableSize
        decoderBufSize

newDispatchHPACKReadHeadersChanIO :: DispatchHPACK e -> IO HeadersChan
newDispatchHPACKReadHeadersChanIO =
    dupChan . _dispatchHPACKWriteHeadersChan

newDispatchHPACKReadPushPromisesChanIO :: DispatchHPACK e -> IO (PushPromisesChan e)
newDispatchHPACKReadPushPromisesChanIO =
    dupChan . _dispatchHPACKWritePushPromisesChan
