{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards  #-}
{-# LANGUAGE RankNTypes  #-}
{-# LANGUAGE MonadComprehensions #-}

-- System architecture
-- * callback for push-promises
-- * outbound flow control
-- * max stream concurrency
-- * do not broadcast to every chan but filter upfront with a lookup
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
    _addCredit   :: WindowSize -> IO ()
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
    _headers      :: HPACK.HeaderList ->
  (HeaderBlockFragment -> [HeaderBlockFragment]) -> (HTTP2.FrameFlags -> HTTP2.FrameFlags) -> IO ClientStreamThread
  , _pushPromise  :: HPACK.HeaderList -> (HeaderBlockFragment -> [HeaderBlockFragment]) -> (HTTP2.FrameFlags -> HTTP2.FrameFlags) -> IO ClientStreamThread
  , _prio         :: HTTP2.Priority -> IO ()
  , _rst          :: HTTP2.ErrorCodeId -> IO ()
  , _waitHeaders  :: IO (HTTP2.FrameHeader, StreamId, Either ErrorCode HeaderList)
  , _waitData     :: IO (HTTP2.FrameHeader, Either ErrorCode ByteString)
  , _sendData     :: (HTTP2.FrameFlags -> HTTP2.FrameFlags) -> ByteString -> IO ()
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

    -- prepare client streams
    clientStreamIdMutex <- newMVar 0
    let withClientStreamId h = bracket (takeMVar clientStreamIdMutex)
            (putMVar clientStreamIdMutex . succ)
            (\k -> h (2 * k + 1)) -- Note: client StreamIds MUST be odd

    let controlStream = makeFrameClientStream conn 0
    let ackPing = sendPingFrame controlStream HTTP2.setAck
    let ackSettings = sendSettingsFrame controlStream HTTP2.setAck []

    -- Initial thread receiving server frames.
    maxReceivedStreamId  <- newIORef 0
    serverFrames <- newChan
    _ <- forkIO $ incomingFramesLoop conn serverFrames maxReceivedStreamId

    -- Thread handling control frames.
    serverSettings  <- newIORef HTTP2.defaultSettings
    _ <- forkIO $ incomingControlFramesLoop serverFrames serverSettings hpackEncoder ackPing ackSettings

    -- Thread handling push-promises and headers frames serializing the buffers.
    serverStreamFrames <- dupChan serverFrames
    serverHeaders <- newChan
    hpackDecoder <- do
        let bufsize  = 4096
        dt <- newDynamicTableForDecoding HPACK.defaultDynamicTableSize bufsize
        return dt
    _ <- forkIO $ incomingHPACKFramesLoop serverStreamFrames serverHeaders hpackDecoder conn onPushPromise

    connectionFlowControl <- newFlowControl controlStream

    let startStream getWork = do
            cont <- withClientStreamId $ \sid -> do
                initializeStream conn
                                 connectionFlowControl
                                 serverFrames
                                 serverHeaders
                                 hpackEncoder
                                 sid
                                 getWork
            cont

    let ping = sendPingFrame controlStream id
    let settings = sendSettingsFrame controlStream id
    let gtfo err errStr = do
            sId <- readIORef maxReceivedStreamId
            sendGTFOFrame controlStream sId err errStr

    return $ Http2Client ping settings gtfo startStream connectionFlowControl

initializeStream conn connectionFlowControl serverFrames serverHeaders hpackEncoder sid getWork = do
    let frameStream = makeFrameClientStream conn sid

    -- Builds a flow-control context.
    streamFlowControl <- newFlowControl frameStream

    -- TODO: use filtered/routed chans abstraction here directly
    frames  <- dupChan serverFrames
    headers <- dupChan serverHeaders

    -- Prepare handlers.
    let _headers      = sendHeaders frameStream hpackEncoder
    let _pushPromise  = sendPushPromise frameStream hpackEncoder
    let _waitHeaders  = waitHeadersWithStreamId sid headers
    let _waitData     = do
            (fh, fp) <- waitFrameWithTypeIdForStreamId sid [HTTP2.FrameRSTStream, HTTP2.FrameData] frames
            case fp of
                DataFrame dat -> do
                     _addCredit streamFlowControl (HTTP2.payloadLength fh)
                     _addCredit connectionFlowControl (HTTP2.payloadLength fh)
                     return (fh, Right dat)
                RSTStreamFrame err -> do
                     return (fh, Left $ HTTP2.fromErrorCodeId err)
    let _sendData     = sendDataFrame frameStream
    let _rst          = sendResetFrame frameStream
    let _prio         = sendPriorityFrame frameStream

    let StreamActions{..} = getWork $ Http2ClientStream{..}

    -- Perform the 1st action, the stream won't be idle anymore.
    _ <- _initStream

    -- Returns 2nd action.
    return $ _handleStream streamFlowControl

incomingFramesLoop conn frames maxReceivedStreamId = forever $ do
    frame@(fh, _) <- next conn
    -- Remember highest streamId.
    atomicModifyIORef' maxReceivedStreamId (\n -> (max n (streamId fh), ()))
    writeChan frames frame

incomingControlFramesLoop frames settings hpackEncoder ackPing ackSettings = forever $ do
    controlFrame@(fh, payload) <- waitFrameWithStreamId 0 frames
    case payload of
        (SettingsFrame settsList) -> when (not . testAck . flags $ fh) $ do
            atomicModifyIORef' settings (\setts -> (HTTP2.updateSettings setts settsList, ()))
            maybe (return ()) (_applySettings hpackEncoder) (lookup SettingsHeaderTableSize settsList)
            ackSettings
        (PingFrame pingMsg) -> when (not . testAck . flags $ fh) $
            ackPing pingMsg
        -- TODO: window updates & co.
        _                   -> print ("unhandled", controlFrame)

incomingHPACKFramesLoop frames headers hpackDecoder = forever $ do
    (fh, fp) <- waitFrameWithTypeId [ HTTP2.FrameRSTStream
                                    , HTTP2.FramePushPromise
                                    , HTTP2.FrameHeaders
                                    ]
                                    frames
    let (sId, pattern) = case fp of
            PushPromiseFrame sid hbf ->
                -- TODO: create streams and prepare a callback
                (sid, Right hbf)
            HeadersFrame _ hbf       -> -- TODO: handle priority
                (HTTP2.streamId fh, Right hbf)
            RSTStreamFrame err       ->
                (HTTP2.streamId fh, Left err)
            _                        -> error "wrong TypeId"

    let go curFh (Right buffer) =
            if not $ HTTP2.testEndHeader (HTTP2.flags curFh)
            then do
                (lastFh, lastFp) <- waitFrameWithTypeId [ HTTP2.FrameRSTStream
                                                        , HTTP2.FrameContinuation
                                                        ]
                                                        frames
                case lastFp of
                    ContinuationFrame chbf ->
                        go lastFh (Right (ByteString.append buffer chbf))
                    RSTStreamFrame err     ->
                        go lastFh (Left err)
            else do
                hdrs <- decodeHeader hpackDecoder buffer
                writeChan headers (curFh, sId, Right hdrs)

        go curFh (Left err) =
                writeChan headers (curFh, sId, (Left $ HTTP2.fromErrorCodeId err))

    go fh pattern

newFlowControl stream = do
    flowControlCredit <- newIORef 0
    let _updateWindow = do
            amount <- atomicModifyIORef' flowControlCredit swapCredit
            when (amount > 0) (sendWindowUpdateFrame stream amount)
    let _addCredit n = atomicModifyIORef' flowControlCredit (\c -> (c + n,()))
    -- TODO: take into accont SETTINGS_INITIAL_WINDOW_SIZE
    return $ FlowControl _addCredit _updateWindow
  where
    swapCredit c
        | c > 0     = (0, c)
        | otherwise = (c, 0)

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

sendDataFrame s mod dat = do
    sendOne s mod (HTTP2.DataFrame dat)

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

sendSettingsFrame s flags setts
  | _getStreamId s /= 0        =
        rfcError "The stream identifier for a SETTINGS frame MUST be zero (0x0)."
  | otherwise                  = do
    let payload = HTTP2.SettingsFrame setts
    sendOne s flags payload
    return ()

-- TODO: need a streamId to add a priority on another stream => we need to expose an opaque StreamId
sendPriorityFrame s p = do
    let payload = HTTP2.PriorityFrame p
    sendOne s id payload
    return ()

waitFrameWithStreamId sid = waitFrame (\h _ -> streamId h == sid)

waitFrameWithTypeId tids = waitFrame (\_ p -> HTTP2.framePayloadToFrameTypeId p `elem` tids)

waitFrameWithTypeIdForStreamId sid tids =
    waitFrame (\h p -> streamId h == sid && HTTP2.framePayloadToFrameTypeId p `elem` tids)

waitFrame pred chan =
    loop
  where
    loop = do
        (fHead, fPayload) <- readChan chan
        let dat = either throw id fPayload
        if pred fHead dat
        then return (fHead, dat)
        else loop

waitHeadersWithStreamId sid = waitHeaders (\_ s _ -> s == sid)

waitHeaders pred chan =
    loop
  where
    loop = do
        tuple@(fH, sId, headers) <- readChan chan
        if pred fH sId headers
        then return tuple
        else loop
