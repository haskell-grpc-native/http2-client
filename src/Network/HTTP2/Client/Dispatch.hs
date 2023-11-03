{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE BangPatterns #-}
module Network.HTTP2.Client.Dispatch where

import           Control.Exception (throwIO)
import           Control.Monad.Base (MonadBase, liftBase)
import           Data.ByteString (ByteString)
import qualified Data.ByteString.Internal as ByteString
import           Foreign.Marshal.Alloc (mallocBytes, finalizerFree)
import           Foreign.ForeignPtr (newForeignPtr)
import           Data.IORef.Lifted (IORef, atomicModifyIORef', newIORef, readIORef)
import           Data.IntMap (IntMap)
import qualified Data.IntMap as IntMap
import           GHC.Exception (Exception)
import           Network.HPACK as HPACK
import qualified Network.HPACK.Token as HPACK
import           Network.HTTP2.Frame as HTTP2

import           Network.HTTP2.Client.Channels
import           Network.HTTP2.Client.Exceptions

type DispatchChan = FramesChan HTTP2Error

-- | A fallback handler for frames.
type FallBackFrameHandler = (FrameHeader, FramePayload) -> ClientIO ()

-- | Default FallBackFrameHandler that ignores frames.
ignoreFallbackHandler :: FallBackFrameHandler
ignoreFallbackHandler = const $ pure ()

-- | An exception thrown when the server sends a GoAwayFrame.
data RemoteSentGoAwayFrame = RemoteSentGoAwayFrame !StreamId !ErrorCodeId !ByteString
  deriving Show
instance Exception RemoteSentGoAwayFrame

-- | A Handler for exceptional circumstances.
type GoAwayHandler = RemoteSentGoAwayFrame -> ClientIO ()

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
defaultGoAwayHandler = lift . throwIO

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

newDispatchIO :: MonadBase IO m => m Dispatch
newDispatchIO = Dispatch <$> newIORef 0 <*> newIORef (IntMap.empty)

readMaxReceivedStreamIdIO :: MonadBase IO m => Dispatch -> m StreamId
readMaxReceivedStreamIdIO = readIORef . _dispatchMaxStreamId

registerStream :: MonadBase IO m => Dispatch -> StreamId -> StreamState -> m ()
registerStream d sid st =
    atomicModifyIORef' (_dispatchCurrentStreams d) $ \xs ->
      let v = (IntMap.insert sid st xs) in (v, ())

lookupStreamState :: MonadBase IO m => Dispatch -> StreamId -> m (Maybe StreamState)
lookupStreamState d sid =
    IntMap.lookup sid <$> readIORef (_dispatchCurrentStreams d)

closeLocalStream :: MonadBase IO m => Dispatch -> StreamId -> m ()
closeLocalStream d sid =
    atomicModifyIORef' (_dispatchCurrentStreams d) $ \xs ->
      let (_,v) = IntMap.updateLookupWithKey f sid xs in (v, ())
  where
    f :: StreamId -> StreamState -> Maybe StreamState
    f _ st = case _streamStateFSMState st of
        HalfClosedRemote -> Nothing
        Closed           -> Nothing
        _ -> Just $ st { _streamStateFSMState = HalfClosedLocal }

closeRemoteStream :: MonadBase IO m => Dispatch -> StreamId -> m ()
closeRemoteStream d sid =
    atomicModifyIORef' (_dispatchCurrentStreams d) $ \xs ->
      let (_,v) = IntMap.updateLookupWithKey f sid xs in (v, ())
  where
    f :: StreamId -> StreamState -> Maybe StreamState
    f _ st = case _streamStateFSMState st of
        HalfClosedLocal  -> Nothing
        Closed           -> Nothing
        _ -> Just $ st { _streamStateFSMState = HalfClosedRemote }

closeReleaseStream :: MonadBase IO m => Dispatch -> StreamId -> m ()
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

newPingHandler :: MonadBase IO m => m PingHandler
newPingHandler = PingHandler <$> newChan

notifyPingHandler :: MonadBase IO m => (FrameHeader, FramePayload) -> PingHandler -> m ()
notifyPingHandler dat (PingHandler c) = writeChan c dat

waitPingReply :: MonadBase IO m => PingHandler -> m (FrameHeader, FramePayload)
waitPingReply (PingHandler c) = readChan c

data SetSettingsHandler = SetSettingsHandler !(Chan (FrameHeader, FramePayload))

newSetSettingsHandler :: MonadBase IO m => m SetSettingsHandler
newSetSettingsHandler = SetSettingsHandler <$> newChan

notifySetSettingsHandler :: MonadBase IO m => (FrameHeader, FramePayload) -> SetSettingsHandler -> m ()
notifySetSettingsHandler dat (SetSettingsHandler c) = writeChan c dat

waitSetSettingsReply :: MonadBase IO m => SetSettingsHandler -> m (FrameHeader, FramePayload)
waitSetSettingsReply (SetSettingsHandler c) = readChan c

registerPingHandler :: DispatchControl -> ByteString -> IO PingHandler
registerPingHandler dc dat = do
    handler <- newPingHandler
    atomicModifyIORef' (_dispatchControlPingHandlers dc) (\xs ->
        ((dat,handler):xs, ()))
    return handler

lookupAndReleasePingHandler :: MonadBase IO m => DispatchControl -> ByteString -> m (Maybe PingHandler)
lookupAndReleasePingHandler dc dat =
    atomicModifyIORef' (_dispatchControlPingHandlers dc) f
  where
    -- Note: we considered doing a single pass for this folds but we expect the
    -- size of handlers to be small anyway (hence, we use a List for
    -- storing the handlers).
    f xs = (filter (\x -> dat /= fst x) xs, lookup dat xs)

registerSetSettingsHandler :: MonadBase IO m => DispatchControl -> m SetSettingsHandler
registerSetSettingsHandler dc = do
    handler <- newSetSettingsHandler
    atomicModifyIORef' (_dispatchControlSetSettingsHandlers dc) (\xs ->
        (handler:xs, ()))
    return handler

lookupAndReleaseSetSettingsHandler :: MonadBase IO m => DispatchControl -> m (Maybe SetSettingsHandler)
lookupAndReleaseSetSettingsHandler dc =
    atomicModifyIORef' (_dispatchControlSetSettingsHandlers dc) f
  where
    f []     = ([], Nothing)
    f (x:xs) = (xs, Just x)

data DispatchControl = DispatchControl {
    _dispatchControlConnectionSettings  :: !(IORef ConnectionSettings)
  , _dispatchControlHpackEncoder        :: !HpackEncoderContext
  , _dispatchControlAckPing             :: !(ByteString -> ClientIO ())
  , _dispatchControlAckSettings         :: !(ClientIO ())
  , _dispatchControlOnGoAway            :: !GoAwayHandler
  , _dispatchControlOnFallback          :: !FallBackFrameHandler
  , _dispatchControlPingHandlers        :: !(IORef [(ByteString, PingHandler)])
  , _dispatchControlSetSettingsHandlers :: !(IORef [SetSettingsHandler])
  }

newDispatchControlIO
  :: MonadBase IO m
  => Size
  -> (ByteString -> ClientIO ())
  -> (ClientIO ())
  -> GoAwayHandler
  -> FallBackFrameHandler
  -> m DispatchControl
newDispatchControlIO encoderBufSize ackPing ackSetts onGoAway onFallback =
    DispatchControl <$> newIORef defaultConnectionSettings
                    <*> newHpackEncoderContext encoderBufSize
                    <*> pure ackPing
                    <*> pure ackSetts
                    <*> pure onGoAway
                    <*> pure onFallback
                    <*> newIORef []
                    <*> newIORef []

newHpackEncoderContext :: MonadBase IO m => Size -> m HpackEncoderContext
newHpackEncoderContext encoderBufSize = liftBase $ do
    let strategy = (HPACK.defaultEncodeStrategy { HPACK.useHuffman = True })
    dt <- HPACK.newDynamicTableForEncoding HPACK.defaultDynamicTableSize
    buf <- mallocBytes encoderBufSize
    ptr <- newForeignPtr finalizerFree buf
    return $ HpackEncoderContext
            (\hdrs -> encoder strategy dt buf ptr hdrs)
            (\n -> HPACK.setLimitForEncoding n dt)
  where
    encoder strategy dt buf ptr hdrs = do
        let hdrs' = fmap (\(k,v) -> let !t = HPACK.toToken k in (t,v)) hdrs
        remainder <- HPACK.encodeTokenHeader buf encoderBufSize strategy True dt hdrs'
        case remainder of
            ([],len) -> pure $ ByteString.fromForeignPtr ptr 0 len
            (_,_)  -> throwIO HPACK.BufferOverrun

readSettings :: MonadBase IO m => DispatchControl -> m ConnectionSettings
readSettings = readIORef . _dispatchControlConnectionSettings

modifySettings :: MonadBase IO m => DispatchControl -> (ConnectionSettings -> (ConnectionSettings, a)) -> m a
modifySettings d = atomicModifyIORef' (_dispatchControlConnectionSettings d)

-- | Helper to carry around the HPACK encoder for outgoing header blocks..
data HpackEncoderContext = HpackEncoderContext {
    _encodeHeaders    :: HeaderList -> IO HeaderBlockFragment
  , _applySettings    :: Size -> IO ()
  }

data DispatchHPACK = DispatchHPACK {
    _dispatchHPACKDynamicTable          :: !DynamicTable
  }

newDispatchHPACKIO :: MonadBase IO m => Size -> m DispatchHPACK
newDispatchHPACKIO decoderBufSize = liftBase $
    DispatchHPACK <$> newDecoder
  where
    newDecoder = newDynamicTableForDecoding
        HPACK.defaultDynamicTableSize
        decoderBufSize

data DispatchStream = DispatchStream {
    _dispatchStreamId         :: !StreamId
  , _dispatchStreamReadEvents :: !(Chan StreamEvent)
  }

newDispatchStreamIO :: MonadBase IO m => StreamId -> m DispatchStream
newDispatchStreamIO sid = liftBase $
    DispatchStream <$> pure sid
                   <*> newChan
