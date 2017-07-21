{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards  #-}
{-# LANGUAGE RankNTypes  #-}
{-# LANGUAGE MonadComprehensions #-}

-- High-level API
-- * allow to reconnect behind the scene when Ids are almost exhausted
-- * split into continuations
-- System architecture
-- * bounded channels
-- * outbound flow control
-- * max stream concurrency
-- * do not broadcast to every chan but filter upfront with a lookup
-- Low-level API
-- * dataframes
module Network.HTTP2.Client (
      Http2Client(..)
    , newHttp2Client
    , Http2ClientStream(..)
    , StreamActions(..)
    , FlowControl(..)
    , dontSplitHeaderBlockFragments
    , module Network.HTTP2.Client.FrameConnection
    ) where

import           Control.Exception (bracket, throw)
import           Control.Concurrent.MVar (newMVar, takeMVar, putMVar)
import           Control.Concurrent (forkIO)
import           Control.Concurrent.Chan (newChan, dupChan, readChan, writeChan)
import           Control.Monad (forever, when)
import           Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import           Data.IORef (newIORef, atomicModifyIORef', readIORef)
import           Network.HPACK as HPACK
import           Network.HTTP2 as HTTP2

import           Network.HTTP2.Client.FrameConnection

data HpackEncoderContext = HpackEncoderContext {
    _encodeHeaders    :: HeaderList -> IO HTTP2.HeaderBlockFragment
  , _applySettings    :: Int -> IO ()
  }

data StreamActions a = StreamActions {
    _initStream   :: IO ClientStreamThread
  , _handleStream :: FlowControl -> IO a
  }

data FlowControl = FlowControl {
    _creditFlow   :: WindowSize -> IO ()
  , _updateWindow :: IO ()
  }

type StreamStarter a =
     (Http2ClientStream -> StreamActions a) -> IO a

data Http2Client = Http2Client {
    _ping             :: ByteString -> IO ()
  , _settings         :: HTTP2.SettingsList -> IO ()
  , _gtfo             :: ErrorCodeId -> ByteString -> IO ()
  , _startStream      :: forall a. StreamStarter a
  , _flowControl      :: FlowControl
  }

-- | Proof that a client stream was initialized.
data ClientStreamThread = CST

data Http2ClientStream = Http2ClientStream {
    _headers      :: HPACK.HeaderList -> (HeaderBlockFragment -> [HeaderBlockFragment]) -> (HTTP2.FrameFlags -> HTTP2.FrameFlags) -> IO ClientStreamThread
  , _pushPromise  :: HPACK.HeaderList -> (HeaderBlockFragment -> [HeaderBlockFragment]) -> (HTTP2.FrameFlags -> HTTP2.FrameFlags) -> IO ClientStreamThread
  , _prio         :: HTTP2.Priority -> IO ()
  , _rst          :: HTTP2.ErrorCodeId -> IO ()
  , _waitFrame    :: IO (HTTP2.FrameHeader, HTTP2.FramePayload)
  }

newHttp2Client host port tlsParams = do
    -- network connection
    conn <- newHttp2FrameConnection host port tlsParams

    -- prepare hpack contexts
    hpackEncoder <- do
        let strategy = (HPACK.defaultEncodeStrategy { HPACK.useHuffman = True })
        let bufsize  = 4096
        dt <- HPACK.newDynamicTableForEncoding HPACK.defaultDynamicTableSize
        let _encodeHeaders = HPACK.encodeHeader strategy bufsize dt
        let _applySettings n = HPACK.setLimitForEncoding n dt
        return HpackEncoderContext{..}

    hpackDecoder <- do
        let bufsize  = 4096
        dt <- newDynamicTableForDecoding HPACK.defaultDynamicTableSize bufsize
        return dt

    -- prepare client streams
    clientStreamIdMutex <- newMVar 0
    let withClientStreamId h = bracket (takeMVar clientStreamIdMutex)
            (putMVar clientStreamIdMutex . succ)
            (\k -> h (2 * k + 1)) -- client StreamIds MUST be odd

    let controlStream = makeFrameClientStream conn 0
    let ackPing = sendPingFrame controlStream HTTP2.setAck

    -- prepare server streams
    maxReceivedStreamId  <- newIORef 0
    serverSettings  <- newIORef HTTP2.defaultSettings
    serverFrames <- newChan

    -- Initial thread receiving server frames.
    _ <- forkIO $ forever $ do
        frame@(fh, _) <- next conn
        -- Remember highest streamId.
        atomicModifyIORef' maxReceivedStreamId (\n -> (max n (streamId fh), ()))
        writeChan serverFrames frame

    -- Thread handling control frames.
    _ <- forkIO $ forever $ do
        controlFrame@(fh, payload) <- waitFrameWithStreamId 0 serverFrames
        case payload of
            (SettingsFrame settsList) -> do
                atomicModifyIORef' serverSettings (\setts -> (HTTP2.updateSettings setts settsList, ()))
                maybe (return ()) (_applySettings hpackEncoder) (lookup SettingsHeaderTableSize settsList)
            (PingFrame pingMsg) -> when (not . testAck . flags $ fh) $
                ackPing pingMsg
            _                         -> print controlFrame

    -- Thread handling push-promises frames.
    -- TODO: propagate decoded headers lists
    _ <- forkIO $ forever $ do
        serverStreamFrames <- dupChan serverFrames
        (fh, fp) <- waitFrameWithTypeId [HTTP2.FramePushPromise, HTTP2.FrameHeaders]
                                        serverStreamFrames
        let (sid, buf0) = case fp of
                PushPromiseFrame sid hbf -> (sid, hbf)
                HeadersFrame _ hbf       -> (HTTP2.streamId fh, hbf)
                _                        -> error "wrong TypeId"
        let go buffer =
                if HTTP2.testEndHeader (HTTP2.flags fh)
                then do
                    print =<< decodeHeader hpackDecoder buffer
                else do
                    (_, ContinuationFrame chbf) <- waitFrameWithTypeId [HTTP2.FrameContinuation]
                                                                       serverStreamFrames
                    go (ByteString.append buffer chbf)
        go buf0


    creditConn <- newFlowControl controlStream
    let startStream getWork = do
            serverStreamFrames <- dupChan serverFrames
            cont <- withClientStreamId $ \sid -> do
                let frameStream = makeFrameClientStream conn sid

                -- Prepare handlers.
                let _headers      = sendHeaders frameStream hpackEncoder
                let _pushPromise  = sendPushPromise frameStream hpackEncoder
                let _waitFrame    = waitFrameWithStreamId sid serverStreamFrames
                let _rst          = sendResetFrame frameStream
                let _prio         = sendPriorityFrame frameStream

                let StreamActions{..} = getWork $ Http2ClientStream{..}

                -- Perform the 1st action, the stream won't be idle anymore.
                _ <- _initStream

                -- Builds a flow-control context.
                streamFlowControl <- newFlowControl controlStream

                -- Returns 2nd action.
                return $ _handleStream streamFlowControl
            cont

    let ping = sendPingFrame controlStream id
    let settings = sendSettingsFrame controlStream
    let gtfo err errStr = do
            sId <- readIORef maxReceivedStreamId
            sendGTFOFrame controlStream sId err errStr

    return $ Http2Client ping settings gtfo startStream creditConn

newFlowControl stream = do
    flowControlCredit <- newIORef 0
    let updateWindow = do
            amount <- atomicModifyIORef' flowControlCredit (\c -> (0, c))
            when (amount > 0) (sendWindowUpdateFrame stream amount)
    let addCredit n = atomicModifyIORef' flowControlCredit (\c -> (c + n,()))
    return $ FlowControl addCredit updateWindow

-- HELPERS

sendHeaders s enc headers blockSplitter mod = do
    headerBlockFragments <- blockSplitter <$> _encodeHeaders enc headers
    let framers           = (HTTP2.HeadersFrame Nothing) : repeat HTTP2.ContinuationFrame
    let frames            = zipWith ($) framers headerBlockFragments
    let modifiersReversed = (HTTP2.setEndHeader . mod) : repeat id
    let arrangedFrames    = reverse $ zip modifiersReversed (reverse frames)
    sendBackToBack s arrangedFrames
    return CST

sendPushPromise s enc headers blockSplitter mod = do
    let sId = _getStreamId s
    headerBlockFragments <- blockSplitter <$> _encodeHeaders enc headers
    let framers           = (HTTP2.PushPromiseFrame sId) : repeat HTTP2.ContinuationFrame
    let frames            = zipWith ($) framers headerBlockFragments
    let modifiersReversed = (HTTP2.setEndHeader . mod) : repeat id
    let arrangedFrames    = reverse $ zip modifiersReversed (reverse frames)
    sendBackToBack s arrangedFrames
    return CST

dontSplitHeaderBlockFragments x = [x]

sendResetFrame s err = do
    sendOne s id (HTTP2.RSTStreamFrame err)

sendGTFOFrame s lastStreamId err errStr = do
    sendOne s id (HTTP2.GoAwayFrame lastStreamId err errStr)

rfcError msg = error (msg ++ "draft-ietf-httpbis-http2-17")

-- | Sends a ping frame.
sendPingFrame s flags dat
  | _getStreamId s /= 0        =
        rfcError "PING frames are not associated with any individual stream."
  | ByteString.length dat /= 8 =
        rfcError "PING frames MUST contain 8 octets"
  | otherwise                  = sendOne s flags (HTTP2.PingFrame dat)

sendWindowUpdateFrame s amount = do
    let payload = HTTP2.WindowUpdateFrame amount
    sendOne s id payload
    return ()

sendSettingsFrame s setts
  | _getStreamId s /= 0        =
        rfcError "The stream identifier for a SETTINGS frame MUST be zero (0x0)."
  | otherwise                  = do
    let payload = HTTP2.SettingsFrame setts
    sendOne s id payload
    return ()

-- TODO: need a streamId to add a priority on another stream => we need to expose an opaque StreamId
sendPriorityFrame s p = do
    let payload = HTTP2.PriorityFrame p
    sendOne s id payload
    return ()

waitFrameWithStreamId sid = waitFrame (\h _ -> streamId h == sid)

waitFrameWithTypeId tids = waitFrame (\_ p -> HTTP2.framePayloadToFrameTypeId p `elem` tids)

waitFrame pred chan =
    loop
  where
    loop = do
        (fHead, fPayload) <- readChan chan
        let dat = either throw id fPayload
        if pred fHead dat
        then return (fHead, dat)
        else loop
