
module Network.HTTP2.Client.Dispatch where

import           Control.Exception (throwIO)
import           Data.ByteString (ByteString)
import           Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import           GHC.Exception (Exception)
import           Network.HPACK as HPACK
import           Network.HTTP2 as HTTP2

import           Network.HTTP2.Client.Channels

type DispatchChan = FramesChan HTTP2Error

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

data StreamState = StreamState {
    _streamStateWindowUpdatesChan :: !(Chan (FrameHeader, FramePayload))
  , _streanStatePushPromisesChan  :: !(Maybe (PushPromisesChan HTTP2Error))
  }

data Dispatch = Dispatch {
    _dispatchWriteChan      :: !DispatchChan
  , _dispatchMaxStreamId    :: !(IORef StreamId)
  , _dispatchCurrentStreams :: !(IORef [(StreamId, StreamState)])
  }

newDispatchIO :: IO Dispatch
newDispatchIO = Dispatch <$> newChan <*> newIORef 0 <*> newIORef []

newDispatchReadChanIO :: Dispatch -> IO DispatchChan
newDispatchReadChanIO = dupChan . _dispatchWriteChan

readMaxReceivedStreamIdIO :: Dispatch -> IO StreamId
readMaxReceivedStreamIdIO = readIORef . _dispatchMaxStreamId

registerStream :: Dispatch -> StreamId -> StreamState -> IO ()
registerStream d sid st =
    atomicModifyIORef' (_dispatchCurrentStreams d) $ \xs ->
      let v = ((sid,st):xs) in (v, ())

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

newDispatchControlIO
  :: Size
  -> (ByteString -> IO ())
  -> (IO ())
  -> GoAwayHandler
  -> FallBackFrameHandler
  -> IO DispatchControl
newDispatchControlIO encoderBufSize ackPing ackSetts onGoAway onFallback =
    DispatchControl <$> newIORef defaultConnectionSettings
                    <*> hpackEncoder
                    <*> pure ackPing
                    <*> pure ackSetts
                    <*> pure onGoAway
                    <*> pure onFallback
  where
    hpackEncoder = do
        let strategy = (HPACK.defaultEncodeStrategy { HPACK.useHuffman = True })
        dt <- HPACK.newDynamicTableForEncoding HPACK.defaultDynamicTableSize
        return $ HpackEncoderContext
            (HPACK.encodeHeader strategy encoderBufSize dt)
            (\n -> HPACK.setLimitForEncoding n dt)

readSettings :: DispatchControl -> IO ConnectionSettings
readSettings = readIORef . _dispatchControlConnectionSettings

modifySettings :: DispatchControl -> (ConnectionSettings -> (ConnectionSettings, a)) -> IO a
modifySettings d = atomicModifyIORef' (_dispatchControlConnectionSettings d)

-- | Helper to carry around the HPACK encoder for outgoing header blocks..
data HpackEncoderContext = HpackEncoderContext {
    _encodeHeaders    :: HeaderList -> IO HeaderBlockFragment
  , _applySettings    :: Size -> IO ()
  }

data DispatchHPACK = DispatchHPACK {
    _dispatchHPACKWriteHeadersChan      :: !HeadersChan
  , _dispatchHPACKDynamicTable          :: !DynamicTable
  }

newDispatchHPACKIO :: Size -> IO DispatchHPACK
newDispatchHPACKIO decoderBufSize =
    DispatchHPACK <$> newChan <*> newDecoder
  where
    newDecoder = newDynamicTableForDecoding
        HPACK.defaultDynamicTableSize
        decoderBufSize

newDispatchHPACKReadHeadersChanIO :: DispatchHPACK -> IO HeadersChan
newDispatchHPACKReadHeadersChanIO =
    dupChan . _dispatchHPACKWriteHeadersChan

data DispatchStream = DispatchStream {
    _dispatchStreamId :: !StreamId
  , _dispatchStreamReadStreamFrames :: !DispatchChan
  , _dispatchStreamReadHeaders      :: !HeadersChan
  , _dispatchStreamReadPushPromises :: Maybe (PushPromisesChan HTTP2Error)
  }

newDispatchStreamIO :: StreamId -> Dispatch -> DispatchHPACK -> IO DispatchStream
newDispatchStreamIO sid d dh =
    DispatchStream <$> pure sid
                   <*> newDispatchReadChanIO d
                   <*> newDispatchHPACKReadHeadersChanIO dh
                   <*> mkPPChan
  where
    -- assuming that client stream IDs must be odd, server streams are even
    -- we can make a push-promise chan or not
    mkPPChan = if odd sid then fmap Just newChan else pure Nothing
