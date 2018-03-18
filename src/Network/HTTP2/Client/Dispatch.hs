{-# LANGUAGE BangPatterns #-}
module Network.HTTP2.Client.Dispatch where

import           Control.Exception (throwIO)
import           Control.Concurrent.STM (STM, atomically, TVar, newTVarIO, readTVar, writeTVar)
import           Data.ByteString (ByteString)
import qualified Data.ByteString.Internal as ByteString
import           Foreign.Marshal.Alloc (mallocBytes, finalizerFree)
import           Foreign.ForeignPtr (newForeignPtr)
import           Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import           Data.IntMap (IntMap)
import qualified Data.IntMap as IntMap
import           GHC.Exception (Exception)
import           Network.HPACK as HPACK
import qualified Network.HPACK.Token as HPACK
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

data StreamFSMState =
    Idle
  | ReservedRemote
  | Open
  | HalfClosedRemote
  | HalfClosedLocal
  | Closed

data StreamEvent =
    StreamHeadersEvent !FrameHeader !HeaderList
  | StreamPushPromiseEvent !FrameHeader !StreamId !HeaderList
  | StreamDataEvent !FrameHeader ByteString
  | StreamErrorEvent !FrameHeader ErrorCode
  deriving Show

data StreamState = StreamState {
    _streamStateWindowUpdatesChan :: !(Chan (FrameHeader, FramePayload))
  , _streamStateEvents            :: !(Chan StreamEvent)
  , _streamStateFSMState          :: !StreamFSMState
  }

data Dispatch = Dispatch {
    _dispatchMaxStreamId    :: !(IORef StreamId)
  , _dispatchCurrentStreams :: !(IORef (IntMap StreamState))
  }

newDispatchIO :: IO Dispatch
newDispatchIO = Dispatch <$> newIORef 0 <*> newIORef (IntMap.empty)

readMaxReceivedStreamIdIO :: Dispatch -> IO StreamId
readMaxReceivedStreamIdIO = readIORef . _dispatchMaxStreamId

registerStream :: Dispatch -> StreamId -> StreamState -> IO ()
registerStream d sid st =
    atomicModifyIORef' (_dispatchCurrentStreams d) $ \xs ->
      let v = (IntMap.insert sid st xs) in (v, ())

lookupStreamState :: Dispatch -> StreamId -> IO (Maybe StreamState)
lookupStreamState d sid =
    IntMap.lookup sid <$> readIORef (_dispatchCurrentStreams d)

closeLocalStream :: Dispatch -> StreamId -> IO ()
closeLocalStream d sid =
    atomicModifyIORef' (_dispatchCurrentStreams d) $ \xs ->
      let (_,v) = IntMap.updateLookupWithKey f sid xs in (v, ())
  where
    f :: StreamId -> StreamState -> Maybe StreamState
    f _ st = case _streamStateFSMState st of
        HalfClosedRemote -> Nothing
        Closed           -> Nothing
        _ -> Just $ st { _streamStateFSMState = HalfClosedLocal }

closeRemoteStream :: Dispatch -> StreamId -> IO ()
closeRemoteStream d sid =
    atomicModifyIORef' (_dispatchCurrentStreams d) $ \xs ->
      let (_,v) = IntMap.updateLookupWithKey f sid xs in (v, ())
  where
    f :: StreamId -> StreamState -> Maybe StreamState
    f _ st = case _streamStateFSMState st of
        HalfClosedLocal  -> Nothing
        Closed           -> Nothing
        _ -> Just $ st { _streamStateFSMState = HalfClosedRemote }

closeReleaseStream :: Dispatch -> StreamId -> IO ()
closeReleaseStream d sid =
    atomicModifyIORef' (_dispatchCurrentStreams d) $ \xs ->
      let v = (IntMap.delete sid xs) in (v, ())

-- | Couples client and server settings together.
data ConnectionSettings = ConnectionSettings {
    _clientSettings :: !Settings
  , _serverSettings :: !Settings
  }

defaultConnectionSettings :: ConnectionSettings
defaultConnectionSettings =
    ConnectionSettings defaultSettings defaultSettings

data PingHandler = PingHandler !(Chan (FrameHeader, FramePayload))

newPingHandler :: IO PingHandler
newPingHandler = PingHandler <$> newChan

notifyPingHandler :: (FrameHeader, FramePayload) -> PingHandler -> IO ()
notifyPingHandler dat (PingHandler c) = writeChan c dat

waitPingReply :: PingHandler -> IO (FrameHeader, FramePayload)
waitPingReply (PingHandler c) = readChan c

data SetSettingsHandler = SetSettingsHandler !(Chan (FrameHeader, FramePayload))

newSetSettingsHandler :: IO SetSettingsHandler
newSetSettingsHandler = SetSettingsHandler <$> newChan

notifySetSettingsHandler :: (FrameHeader, FramePayload) -> SetSettingsHandler -> IO ()
notifySetSettingsHandler dat (SetSettingsHandler c) = writeChan c dat

waitSetSettingsReply :: SetSettingsHandler -> IO (FrameHeader, FramePayload)
waitSetSettingsReply (SetSettingsHandler c) = readChan c

registerPingHandler :: DispatchControl -> ByteString -> IO PingHandler
registerPingHandler dc dat = do
    handler <- newPingHandler
    atomicModifyIORef' (_dispatchControlPingHandlers dc) (\xs ->
        ((dat,handler):xs, ()))
    return handler

lookupAndReleasePingHandler :: DispatchControl -> ByteString -> IO (Maybe PingHandler)
lookupAndReleasePingHandler dc dat =
    atomicModifyIORef' (_dispatchControlPingHandlers dc) f
  where
    -- Note: we considered doing a single pass for this folds but we expect the
    -- size of handlers to be small anyway (hence, we use a List for
    -- storing the handlers).
    f xs = (filter (\x -> dat /= fst x) xs, lookup dat xs)

registerSetSettingsHandler :: DispatchControl -> IO SetSettingsHandler
registerSetSettingsHandler dc = do
    handler <- newSetSettingsHandler
    atomicModifyIORef' (_dispatchControlSetSettingsHandlers dc) (\xs ->
        (handler:xs, ()))
    return handler

lookupAndReleaseSetSettingsHandler :: DispatchControl -> IO (Maybe SetSettingsHandler)
lookupAndReleaseSetSettingsHandler dc =
    atomicModifyIORef' (_dispatchControlSetSettingsHandlers dc) f
  where
    f []     = ([], Nothing)
    f (x:xs) = (xs, Just x)

data DispatchControl = DispatchControl {
    _dispatchControlConnectionSettings  :: !(TVar ConnectionSettings)
  , _dispatchControlHpackEncoder        :: !HpackEncoderContext
  , _dispatchControlAckPing             :: !(ByteString -> IO ())
  , _dispatchControlAckSettings         :: !(IO ())
  , _dispatchControlOnGoAway            :: !GoAwayHandler
  , _dispatchControlOnFallback          :: !FallBackFrameHandler
  , _dispatchControlPingHandlers        :: !(IORef [(ByteString, PingHandler)])
  , _dispatchControlSetSettingsHandlers :: !(IORef [SetSettingsHandler])
  }

newDispatchControlIO
  :: Size
  -> (ByteString -> IO ())
  -> (IO ())
  -> GoAwayHandler
  -> FallBackFrameHandler
  -> IO DispatchControl
newDispatchControlIO encoderBufSize ackPing ackSetts onGoAway onFallback =
    DispatchControl <$> newTVarIO defaultConnectionSettings
                    <*> newHpackEncoderContext encoderBufSize
                    <*> pure ackPing
                    <*> pure ackSetts
                    <*> pure onGoAway
                    <*> pure onFallback
                    <*> newIORef []
                    <*> newIORef []

newHpackEncoderContext :: Size -> IO HpackEncoderContext
newHpackEncoderContext encoderBufSize = do
    let strategy = (HPACK.defaultEncodeStrategy { HPACK.useHuffman = True })
    dt <- HPACK.newDynamicTableForEncoding HPACK.defaultDynamicTableSize
    buf <- mallocBytes encoderBufSize
    ptr <- newForeignPtr finalizerFree buf
    return $ HpackEncoderContext
            (encoder strategy dt buf ptr)
            (\n -> HPACK.setLimitForEncoding n dt)
  where
    encoder strategy dt buf ptr hdrs = do
        let hdrs' = fmap (\(k,v) -> let !t = HPACK.toToken k in (t,v)) hdrs
        remainder <- HPACK.encodeTokenHeader buf encoderBufSize strategy True dt hdrs'
        case remainder of
            ([],len) -> pure $ ByteString.fromForeignPtr ptr 0 len
            (_,_)  -> throwIO HPACK.BufferOverrun

readSettings :: DispatchControl -> IO ConnectionSettings
readSettings = atomically . readTVar . _dispatchControlConnectionSettings

modifySettings :: DispatchControl -> (ConnectionSettings -> (ConnectionSettings, a)) -> IO a
modifySettings d f = atomically $ do
    let t = _dispatchControlConnectionSettings d
    oldVal <- readTVar t
    let (!newVal, !res) = f oldVal
    writeTVar t newVal
    return res

-- | Helper to carry around the HPACK encoder for outgoing header blocks..
data HpackEncoderContext = HpackEncoderContext {
    _encodeHeaders    :: HeaderList -> IO HeaderBlockFragment
  , _applySettings    :: Size -> IO ()
  }

data DispatchHPACK = DispatchHPACK {
    _dispatchHPACKDynamicTable          :: !DynamicTable
  }

newDispatchHPACKIO :: Size -> IO DispatchHPACK
newDispatchHPACKIO decoderBufSize =
    DispatchHPACK <$> newDecoder
  where
    newDecoder = newDynamicTableForDecoding
        HPACK.defaultDynamicTableSize
        decoderBufSize

data DispatchStream = DispatchStream {
    _dispatchStreamId         :: !StreamId
  , _dispatchStreamReadEvents :: !(Chan StreamEvent)
  }

newDispatchStreamIO :: StreamId -> IO DispatchStream
newDispatchStreamIO sid =
    DispatchStream <$> pure sid
                   <*> newChan
