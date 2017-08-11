{-# LANGUAGE RecordWildCards  #-}
{-# LANGUAGE RankNTypes  #-}

-- TODO:
-- * chunking based on SETTINGS
-- * do not broadcast to every chan but filter upfront with a lookup
-- * help to verify authority of push promises
-- * more strict with protocol checks/goaway/errors
-- * proper exceptions handling/throwing
module Network.HTTP2.Client (
      Http2Client(..)
    , newHttp2Client
    , PushPromiseHandler
    , Http2Stream(..)
    , StreamThread
    , _gtfo
    , StreamDefinition(..)
    , IncomingFlowControl(..)
    , OutgoingFlowControl(..)
    , dontSplitHeaderBlockFragments
    , module Network.HTTP2.Client.FrameConnection
    , module Network.Socket
    , module Network.TLS
    ) where

import           Control.Exception (bracket, throw)
import           Control.Concurrent.Async (race)
import           Control.Concurrent.MVar (newMVar, takeMVar, putMVar)
import           Control.Concurrent (forkIO, threadDelay)
import           Control.Concurrent.Chan (Chan, newChan, dupChan, readChan, writeChan)
import           Control.Monad (forever, when)
import           Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import           Data.IORef (IORef, newIORef, atomicModifyIORef', readIORef)
import           Data.Maybe (fromMaybe)
import           GHC.Exception (Exception)
import           Network.HPACK as HPACK
import           Network.HTTP2 as HTTP2
import           Network.Socket (HostName, PortNumber)
import           Network.TLS (ClientParams)

import           Network.HTTP2.Client.FrameConnection

-- | Offers credit-based flow-control.
-- 
-- Any mutable changes are atomic and hence work as intended in a multithreaded
-- setup.
--
-- The design of the flow-control mechanism is subject to changes.  One
-- important thing to keep in mind with current implementation is that both the
-- connection and streams are credited with '_addCredit' as soon as DATA frames
-- arrive, hence no-need to account for the DATA frames (but you can account
-- for delay-bandwidth product for instance).
data IncomingFlowControl = IncomingFlowControl {
    _addCredit   :: WindowSize -> IO ()
  -- ^ Add credit (using a hidden mutable reference underneath). This function
  -- only does accounting, the IO only does mutable changes. See '_updateWindow'.
  , _consumeCredit :: WindowSize -> IO () --TODO: return whether total credit became negative and we should trigger a connection error
  -- ^ Consumes some credit.
  , _updateWindow :: IO ()
  -- ^ Sends a WINDOW_UPDATE frame crediting it with the whole amount credited
  -- since the last _updateWindow call.
  }

-- | Receives credit-based flow-control or block.
--
-- There is no way to observe the total amount of credit and receive/withdraw
-- are atomic hence this object is thread-safe. However we plan to propose an
-- STM-based API to allow withdrawing atomically from both the connection and a
-- per-stream 'OutgoingFlowControl' objects at a same time. Without such
-- atomicity one must ensure consumers do not exhaust the connection credit
-- before taking the per-stream credit (else they might prevent others sending
-- data without taking any).
--
-- Longer term we plan to hide outgoing-flow-control increment/decrement
-- altogether because exception between withdrawing credit and sending DATA
-- could mean lost credit (and hence hanging streams).
data OutgoingFlowControl = OutgoingFlowControl {
    _receiveCredit  :: WindowSize -> IO ()
  -- ^ Add credit (using a hidden mutable reference underneath).
  , _withdrawCredit :: WindowSize -> IO WindowSize
  -- ^ Wait until we can take credit from stash. The returned value correspond
  -- to the amount that could be withdrawn, which is min(current, wanted). A
  -- caller should withdraw credit to send DATA chunks and put back any unused
  -- credit with _receiveCredit.
  }

-- | Defines a client stream.
--
-- Please red the doc for this record fields and then see 'StreamStarter'.
data StreamDefinition a = StreamDefinition {
    _initStream   :: IO StreamThread
  -- ^ Function to initialize a new client stream. This function runs in a
  -- exclusive-access section of the code and may prevent other threads to
  -- initialize new streams. Hence, you should ensure this IO does not wait for
  -- long periods of time.
  , _handleStream :: IncomingFlowControl -> OutgoingFlowControl -> IO a
  -- ^ Function to operate with the stream. IncomingFlowControl currently is
  -- credited on your behalf as soon as a DATA frame arrives (and before you
  -- handle it with '_waitData'). However we do not send WINDOW_UPDATE with
  -- '_updateWindow'. This design may change in the future to give more leeway
  -- to library users.
  }

-- | Type alias for callback-based functions starting new streams.
--
-- The callback a user must provide takes an 'Http2Stream' and returns a
-- 'StreamDefinition'. This construction may seem wrong because a 'StreamDefinition'
-- contains an initialization and a handler functions. The explanation for this
-- twistedness is as follows: in HTTP2 stream-ids must be monotonically
-- increasing, if we want to support multi-threaded clients we need to
-- serialize access to a critical region of the code when clients send
-- HEADERS+CONTINUATIONs frames.
--
-- Passing the 'Http2Stream' object as part of the callback avoids leaking the
-- implementation of the critical region, meanwhile, the 'StreamDefinition'
-- delimits this critical region.
type StreamStarter a =
     (Http2Stream -> StreamDefinition a) -> IO (Either TooMuchConcurrency a)

newtype TooMuchConcurrency = TooMuchConcurrency Int
    deriving Show

-- | Record holding functions one can call while in an HTTP2 client session.
data Http2Client = Http2Client {
    _ping             :: ByteString -> IO (IO (FrameHeader, FramePayload))
  -- ^ Send a PING, the payload size must be exactly eight bytes.
  -- Returns an IO to wait for a ping reply. No timeout is provided. Only the
  -- first call to this IO will return if a reply is received. Hence we
  -- recommend wrapping this IO in an Async (e.g., with @race (threadDelay
  -- timeout)@.)
  , _settings         :: SettingsList -> IO ()
  -- ^ Sends a SETTINGS.
  , _goaway           :: ErrorCodeId -> ByteString -> IO ()
  -- ^ Sends a GOAWAY. 
  , _startStream      :: forall a. StreamStarter a
  -- ^ Spawns new streams. See 'StreamStarter'.
  , _incomingFlowControl :: IncomingFlowControl
  -- ^ Simple getter for the 'IncomingFlowControl' for the whole client
  -- connection.
  , _outgoingFlowControl :: OutgoingFlowControl
  -- ^ Simple getter for the 'OutgoingFlowControl' for the whole client
  -- connection.
  }

-- | Couples client and server settings together.
data ConnectionSettings = ConnectionSettings {
    _clientSettings :: !Settings
  , _serverSettings :: !Settings
  }

defaultConnectionSettings :: ConnectionSettings
defaultConnectionSettings =
    ConnectionSettings defaultSettings defaultSettings

-- | Synonym of '_goaway'.
--
-- https://github.com/http2/http2-spec/pull/366
_gtfo :: Http2Client -> ErrorCodeId -> ByteString -> IO ()
_gtfo = _goaway

-- | Opaque proof that a client stream was initialized.
--
-- This type is only useful to force calling '_headers' in '_initStream' and
-- contains no information.
data StreamThread = CST

-- | Record holding functions one can call while in an HTTP2 client stream.
data Http2Stream = Http2Stream {
    _headers      :: HPACK.HeaderList
                  -> HeaderBlockSplitter
                  -> (FrameFlags -> FrameFlags)
                  -> IO StreamThread
  -- ^ Starts the stream with HTTP headers. Flags modifier can use
  -- 'setEndStream' if no data is required passed the last block of headers.
  -- Usually, this is the only call needed to build an '_initStream'.
  , _prio         :: Priority -> IO ()
  -- ^ Changes the PRIORITY of this stream.
  , _rst          :: ErrorCodeId -> IO ()
  -- ^ Resets this stream with a RST frame. You should not use this stream past this call.
  , _waitHeaders  :: IO (FrameHeader, StreamId, Either ErrorCode HeaderList)
  -- ^ Waits for HTTP headers from the server. This function also passes the
  -- last frame header of the PUSH-PROMISE, HEADERS, or CONTINUATION sequence of frames.
  -- Waiting more than once per stream will hang as headers are sent only one time.
  , _waitData     :: IO (FrameHeader, Either ErrorCode ByteString)
  -- ^ Waits for a DATA frame chunk. A user should testEndStream on the frame
  -- header to know when the server is done with the stream.
  , _sendData     :: (FrameFlags -> FrameFlags) -> ByteString -> IO ()
  -- ^ Sends a DATA frame chunk. You can use send empty frames with only
  -- headers modifiers to close streams. This function is oblivious to framing
  -- and hence does not respect the RFC if sending large blocks (but is the
  -- only alternative for now).
  }

-- | Handler upon receiving a PUSH_PROMISE from the server.
--
-- The functions for 'Http2Stream' are similar to those used in ''. But callers
-- shall not use '_headers' to initialize the PUSH_PROMISE stream. Rather,
-- callers should 'waitHeaders' or '_rst' to reject the PUSH_PROMISE.
--
-- The StreamId corresponds to the parent stream as PUSH_PROMISEs are tied to a
-- client-initiated stream. Longer term we may move passing this handler to the
-- '_startStream' instead of 'newHttp2Client' (as it is for now).
type PushPromiseHandler a =
    StreamId -> Http2Stream -> IncomingFlowControl -> OutgoingFlowControl -> IO a

-- | Helper to carry around the HPACK encoder for outgoing header blocks..
data HpackEncoderContext = HpackEncoderContext {
    _encodeHeaders    :: HeaderList -> IO HeaderBlockFragment
  , _applySettings    :: Int -> IO ()
  }

-- | Starts a new Http2Client with a remote Host/Port. TLS ClientParams are
-- mandatory because we only support TLS-protected streams for now.
newHttp2Client :: HostName
               -- ^ Host to connect to.
               -> PortNumber
               -- ^ Port number to connect to (usually 443 on the web).
               -> ClientParams
               -- ^ The TLS client parameters (e.g., to allow some certificates).
               -> PushPromiseHandler a
               -- ^ Action to perform when a server sends a PUSH_PROMISE.
               -> IO Http2Client
newHttp2Client host port tlsParams handlePPStream = do
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
    settings  <- newIORef defaultConnectionSettings
    controlFrames <- dupChan serverFrames
    _ <- forkIO $ incomingControlFramesLoop controlFrames settings hpackEncoder ackPing ackSettings

    -- Thread handling push-promises and headers frames serializing the buffers.
    serverStreamFrames <- dupChan serverFrames
    serverHeaders <- newChan
    hpackDecoder <- do
        let bufsize  = 4096
        dt <- newDynamicTableForDecoding HPACK.defaultDynamicTableSize bufsize
        return dt

    creditFrames <- dupChan serverFrames

    _outgoingFlowControl <- newOutgoingFlowControl settings 0 creditFrames
    _incomingFlowControl <- newIncomingFlowControl settings controlStream

    _ <- forkIO $ incomingHPACKFramesLoop serverStreamFrames
                                          serverHeaders
                                          hpackEncoder
                                          hpackDecoder
                                          conn
                                          settings
                                          _incomingFlowControl
                                          handlePPStream

    conccurentStreams <- newIORef 0
    let _startStream getWork = do
            maxConcurrency <- fromMaybe 100 . maxConcurrentStreams . _serverSettings
               <$> readIORef settings
            roomNeeded <- atomicModifyIORef' conccurentStreams
                (\n -> if n < maxConcurrency then (n + 1, 0) else (n, 1 + n - maxConcurrency))
            if roomNeeded > 0
            then
                return $ Left $ TooMuchConcurrency roomNeeded
            else do
                cont <- withClientStreamId $ \sid -> do
                    initializeStream conn
                                     settings
                                     _incomingFlowControl
                                     serverFrames
                                     serverHeaders
                                     hpackEncoder
                                     sid
                                     getWork
                v <- cont
                atomicModifyIORef' conccurentStreams (\n -> (n - 1, ()))
                return $ Right v

    let _ping dat = do
            -- Need to dupChan before sending the query to avoid missing a fast
            -- answer if the network is fast.
            pingFrames <- dupChan serverFrames
            sendPingFrame controlStream id dat
            return $ waitFrame (isPingReply dat) serverFrames
    let _settings settslist = do
            atomicModifyIORef' settings
                       (\(ConnectionSettings cli srv) ->
                           (ConnectionSettings (HTTP2.updateSettings cli settslist) srv, ()))
            sendSettingsFrame controlStream id settslist
    let _goaway err errStr = do
            sId <- readIORef maxReceivedStreamId
            sendGTFOFrame controlStream sId err errStr

    return $ Http2Client{..}

initializeStream
  :: Exception e
  => Http2FrameConnection
  -> IORef ConnectionSettings
  -> IncomingFlowControl
  -> Chan (FrameHeader, Either e FramePayload)
  -> Chan (FrameHeader, StreamId, Either ErrorCode HeaderList)
  -> HpackEncoderContext
  -> StreamId
  -> (Http2Stream -> StreamDefinition a)
  -> IO (IO a)
initializeStream conn settings connectionFlowControl serverFrames serverHeaders hpackEncoder sid getWork = do
    let frameStream = makeFrameClientStream conn sid

    -- Register interest in frames.
    frames  <- dupChan serverFrames
    credits <- dupChan serverFrames
    headers <- dupChan serverHeaders

    -- Builds a flow-control context.
    incomingStreamFlowControl <- newIncomingFlowControl settings frameStream
    outgoingStreamFlowControl <- newOutgoingFlowControl settings sid credits

    -- Prepare handlers.
    let _headers      = sendHeaders frameStream hpackEncoder
    let _waitHeaders  = waitHeadersWithStreamId sid headers
    let _waitData     = do
            (fh, fp) <- waitFrameWithTypeIdForStreamId sid [FrameRSTStream, FrameData] frames
            case fp of
                DataFrame dat -> do
                     _consumeCredit incomingStreamFlowControl (HTTP2.payloadLength fh)
                     _consumeCredit connectionFlowControl (HTTP2.payloadLength fh) -- TODO: move this one to the main thread because we must count DATA frames even after a RST and here this is not guaranteed
                     _addCredit incomingStreamFlowControl (HTTP2.payloadLength fh)
                     _addCredit connectionFlowControl (HTTP2.payloadLength fh) -- TODO: move this one to the main thread because we must count DATA frames even after a RST and here this is not guaranteed
                     return (fh, Right dat)
                RSTStreamFrame err -> do
                     return (fh, Left $ HTTP2.fromErrorCodeId err)
    let _sendData     = sendDataFrame frameStream
    let _rst          = sendResetFrame frameStream
    let _prio         = sendPriorityFrame frameStream

    let streamActions = getWork $ Http2Stream{..}

    -- Perform the 1st action, the stream won't be idle anymore.
    _ <- _initStream streamActions

    -- Returns 2nd action.
    return $ _handleStream streamActions incomingStreamFlowControl outgoingStreamFlowControl

incomingFramesLoop
  :: Http2FrameConnection
  -> Chan (FrameHeader, Either HTTP2Error FramePayload)
  -> IORef StreamId
  -> IO ()
incomingFramesLoop conn frames maxReceivedStreamId = forever $ do
    frame@(fh, _) <- next conn
    -- Remember highest streamId.
    atomicModifyIORef' maxReceivedStreamId (\n -> (max n (streamId fh), ()))
    writeChan frames frame

incomingControlFramesLoop
  :: Exception e
  => Chan (FrameHeader, Either e FramePayload)
  -> IORef ConnectionSettings
  -> HpackEncoderContext
  -> (ByteString -> IO ())
  -> IO ()
  -> IO ()
incomingControlFramesLoop frames settings hpackEncoder ackPing ackSettings = forever $ do
    controlFrame@(fh, payload) <- waitFrameWithStreamId 0 frames
    case payload of
        (SettingsFrame settsList)
            | not . testAck . flags $ fh -> do
                atomicModifyIORef' settings
                                   (\(ConnectionSettings cli srv) ->
                                      (ConnectionSettings cli (HTTP2.updateSettings srv settsList), ()))
                maybe (return ())
                      (_applySettings hpackEncoder)
                      (lookup SettingsHeaderTableSize settsList)
                ackSettings
        (PingFrame pingMsg)
            | not . testAck . flags $ fh ->
                ackPing pingMsg
        _                   -> print ("unhandled", controlFrame)

incomingHPACKFramesLoop
  :: Exception e
  => Chan (FrameHeader, Either e FramePayload)
  -> Chan (FrameHeader, StreamId, Either ErrorCode HeaderList)
  -> HpackEncoderContext
  -> DynamicTable
  -> Http2FrameConnection
  -> IORef ConnectionSettings
  -> IncomingFlowControl
  -> PushPromiseHandler a
  -> IO ()
incomingHPACKFramesLoop frames headers hpackEncoder hpackDecoder conn settings connectionFlowControl handlePPStream = forever $ do
    (fh, fp) <- waitFrameWithTypeId [ FrameRSTStream
                                    , FramePushPromise
                                    , FrameHeaders
                                    ]
                                    frames
    (sId, pattern) <- case fp of
            PushPromiseFrame sid hbf -> do
                let parentSid = HTTP2.streamId fh
                let mkStreamActions stream = StreamDefinition (return CST) (handlePPStream parentSid stream)
                cont <- initializeStream conn
                                         settings
                                         connectionFlowControl
                                         frames
                                         headers
                                         hpackEncoder
                                         sid
                                         mkStreamActions
                cont
                return (sid, Right hbf)
            HeadersFrame _ hbf       -> -- TODO: handle priority
                return (HTTP2.streamId fh, Right hbf)
            RSTStreamFrame err       ->
                return (HTTP2.streamId fh, Left err)
            _                        -> error "wrong TypeId"

    let go curFh (Right buffer) =
            if not $ HTTP2.testEndHeader (HTTP2.flags curFh)
            then do
                (lastFh, lastFp) <- waitFrameWithTypeId [ FrameRSTStream
                                                        , FrameContinuation
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

newIncomingFlowControl :: IORef ConnectionSettings -> Http2FrameClientStream -> IO IncomingFlowControl
newIncomingFlowControl settings stream = do
    credit <- newIORef 0
    let _updateWindow = do
            base <- initialWindowSize . _clientSettings <$> readIORef settings
            current <- readIORef credit
            let amount = base + current
            print ("****", base, current, amount)
            when (amount > 0) (sendWindowUpdateFrame stream amount)
    let _addCredit n = atomicModifyIORef' credit (\c -> (c + n,()))
    let _consumeCredit n = atomicModifyIORef' credit (\c -> (c - n,()))
    return $ IncomingFlowControl _addCredit _consumeCredit _updateWindow

newOutgoingFlowControl ::
     Exception e
  => IORef ConnectionSettings
  -> StreamId
  -> Chan (FrameHeader, Either e FramePayload)
  -> IO OutgoingFlowControl
newOutgoingFlowControl settings sid frames = do
    credit <- newIORef 0
    let receive n = atomicModifyIORef' credit (\c -> (c + n, ()))
    let withdraw n = do
            base <- initialWindowSize . _serverSettings <$> readIORef settings
            got <- atomicModifyIORef' credit (\c ->
                    if base + c >= n
                    then (c - n, n)
                    else (0 - base, base + c))
            if got > 0
            then return got
            else do
                amount <- race (waitSettingsChange base) waitSomeCredit
                receive (either (const 0) id amount)
                withdraw n
    return $ OutgoingFlowControl receive withdraw
  where
    -- TODO: broadcast settings changes from ConnectionSettings using a better data type
    -- than IORef+busy loop. Currently the busy loop is fine because
    -- SettingsInitialWindowSize is typically set at the first frame and hence
    -- waiting one second for an update that is likely to never come is
    -- probably not an issue. There still is an opportunity risk, however, that
    -- an hasted client asks for X > initialWindowSize before the server has
    -- sent its initial SETTINGS frame.
    waitSettingsChange prev = do
            new <- initialWindowSize . _serverSettings <$> readIORef settings
            if new == prev then threadDelay 1000000 >> waitSettingsChange prev else return ()
    waitSomeCredit = do
        (fh, fp) <- waitFrameWithTypeIdForStreamId sid [FrameWindowUpdate] frames
        case fp of
            WindowUpdateFrame amt -> return amt

sendHeaders
  :: Http2FrameClientStream
  -> HpackEncoderContext
  -> HeaderList
  -> HeaderBlockSplitter
  -> (FrameFlags -> FrameFlags)
  -> IO StreamThread
sendHeaders s enc headers blockSplitter mod = do
    headerBlockFragments <- blockSplitter <$> _encodeHeaders enc headers
    let framers           = (HeadersFrame Nothing) : repeat ContinuationFrame
    let frames            = zipWith ($) framers headerBlockFragments
    let modifiersReversed = (HTTP2.setEndHeader . mod) : repeat id
    let arrangedFrames    = reverse $ zip modifiersReversed (reverse frames)
    sendBackToBack s arrangedFrames
    return CST

-- | A function able to split a header block into multiple fragments.
type HeaderBlockSplitter = HeaderBlockFragment -> [HeaderBlockFragment]

-- | Sends all in a single HEADERS frame.
--
-- This function is oblivious to any framing (and hence does not respect the
-- RFC) but is the only alternative proposed by this library at the moment.
dontSplitHeaderBlockFragments :: HeaderBlockSplitter
dontSplitHeaderBlockFragments x = [x]

sendDataFrame
  :: Http2FrameClientStream
  -> (FrameFlags -> FrameFlags) -> ByteString -> IO ()
sendDataFrame s mod dat = do
    sendOne s mod (DataFrame dat)

sendResetFrame :: Http2FrameClientStream -> ErrorCodeId -> IO ()
sendResetFrame s err = do
    sendOne s id (RSTStreamFrame err)

sendGTFOFrame
  :: Http2FrameClientStream
     -> StreamId -> ErrorCodeId -> ByteString -> IO ()
sendGTFOFrame s lastStreamId err errStr = do
    sendOne s id (GoAwayFrame lastStreamId err errStr)

rfcError :: String -> a
rfcError msg = error (msg ++ "draft-ietf-httpbis-http2-17")

sendPingFrame
  :: Http2FrameClientStream
  -> (FrameFlags -> FrameFlags)
  -> ByteString
  -> IO ()
sendPingFrame s flags dat
  | _getStreamId s /= 0        =
        rfcError "PING frames are not associated with any individual stream."
  | ByteString.length dat /= 8 =
        rfcError "PING frames MUST contain 8 octets"
  | otherwise                  = sendOne s flags (PingFrame dat)

sendWindowUpdateFrame
  :: Http2FrameClientStream -> WindowSize -> IO ()
sendWindowUpdateFrame s amount = do
    let payload = WindowUpdateFrame amount
    sendOne s id payload
    return ()

sendSettingsFrame
  :: Http2FrameClientStream
     -> (FrameFlags -> FrameFlags) -> SettingsList -> IO ()
sendSettingsFrame s flags setts
  | _getStreamId s /= 0        =
        rfcError "The stream identifier for a SETTINGS frame MUST be zero (0x0)."
  | otherwise                  = do
    let payload = SettingsFrame setts
    sendOne s flags payload
    return ()

-- TODO: need a streamId to add a priority on another stream
sendPriorityFrame :: Http2FrameClientStream -> Priority -> IO ()
sendPriorityFrame s p = do
    let payload = PriorityFrame p
    sendOne s id payload
    return ()

waitFrameWithStreamId
  :: Exception e =>
     StreamId -> Chan (FrameHeader, Either e FramePayload) -> IO (FrameHeader, FramePayload)
waitFrameWithStreamId sid = waitFrame (\h _ -> streamId h == sid)

waitFrameWithTypeId
  :: (Exception e)
  => [FrameTypeId]
  -> Chan (FrameHeader, Either e FramePayload) -> IO (FrameHeader, FramePayload)
waitFrameWithTypeId tids = waitFrame (\_ p -> HTTP2.framePayloadToFrameTypeId p `elem` tids)

waitFrameWithTypeIdForStreamId
  :: (Exception e)
  => StreamId
  -> [FrameTypeId]
  -> Chan (FrameHeader, Either e FramePayload)
  -> IO (FrameHeader, FramePayload)
waitFrameWithTypeIdForStreamId sid tids =
    waitFrame (\h p -> streamId h == sid && HTTP2.framePayloadToFrameTypeId p `elem` tids)

waitFrame
  :: Exception e
  => (FrameHeader -> FramePayload -> Bool)
  -> Chan (FrameHeader, Either e FramePayload)
  -> IO (FrameHeader, FramePayload)
waitFrame pred chan =
    loop
  where
    loop = do
        (fHead, fPayload) <- readChan chan
        let dat = either throw id fPayload
        if pred fHead dat
        then return (fHead, dat)
        else loop

isPingReply :: ByteString -> FrameHeader -> FramePayload -> Bool
isPingReply datSent _ (PingFrame datRcv) = datSent == datRcv
isPingReply _       _ _                  = False

waitHeadersWithStreamId
  :: StreamId
  -> Chan (FrameHeader, StreamId, t)
  -> IO (FrameHeader, StreamId, t)
waitHeadersWithStreamId sid =
    waitHeaders (\_ s _ -> s == sid)

waitHeaders
  :: (FrameHeader -> StreamId -> t -> Bool)
  -> Chan (FrameHeader, StreamId, t)
  -> IO (FrameHeader, StreamId, t)
waitHeaders pred chan =
    loop
  where
    loop = do
        tuple@(fH, sId, headers) <- readChan chan
        if pred fH sId headers
        then return tuple
        else loop
