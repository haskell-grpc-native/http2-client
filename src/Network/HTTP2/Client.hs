{-# LANGUAGE FlexibleContexts   #-}
{-# LANGUAGE RecordWildCards    #-}
{-# LANGUAGE RankNTypes         #-}
{-# LANGUAGE OverloadedStrings  #-}

-- | This module defines a set of low-level primitives for starting an HTTP2
-- session and interacting with a server.
--
-- For higher-level primitives, please refer to Network.HTTP2.Client.Helpers .
module Network.HTTP2.Client (
    -- * Basics
      runHttp2Client
    , newHttp2Client
    , withHttp2Stream
    , headers
    , trailers
    , sendData
    -- * Starting clients
    , Http2Client(..)
    , PushPromiseHandler
    -- * Starting streams
    , StreamDefinition(..)
    , StreamStarter
    , TooMuchConcurrency(..)
    , StreamThread
    , Http2Stream(..)
    -- * Flow control
    , IncomingFlowControl(..)
    , OutgoingFlowControl(..)
    -- * Exceptions
    , linkAsyncs
    , RemoteSentGoAwayFrame(..)
    , GoAwayHandler
    , defaultGoAwayHandler
    -- * Misc.
    , FallBackFrameHandler
    , ignoreFallbackHandler
    , FlagSetter
    , Http2ClientAsyncs(..)
    , _gtfo
    -- * Convenience re-exports
    , StreamEvent(..)
    , module Network.HTTP2.Client.FrameConnection
    , module Network.HTTP2.Client.Exceptions
    , module Network.Socket
    , module Network.TLS
    ) where

import           Control.Concurrent.Async.Lifted (Async, async, race, withAsync, link)
import           Control.Exception.Lifted (bracket, throwIO, SomeException, catch)
import           Control.Concurrent.MVar.Lifted (newEmptyMVar, newMVar, putMVar, takeMVar, tryPutMVar)
import           Control.Concurrent.Lifted (threadDelay)
import           Control.Monad (forever, void, when, forM_)
import           Control.Monad.IO.Class (liftIO)
import           Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import           Data.IORef.Lifted (newIORef, atomicModifyIORef', readIORef)
import           Data.Maybe (fromMaybe)
import           Network.HPACK as HPACK
import           Network.HTTP2.Frame as HTTP2
import           Network.Socket (HostName, PortNumber)
import           Network.TLS (ClientParams)

import           Network.HTTP2.Client.Channels
import           Network.HTTP2.Client.Dispatch
import           Network.HTTP2.Client.Exceptions
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
  , _consumeCredit :: WindowSize -> IO Int
  -- ^ Consumes some credit and returns the credit left.
  , _updateWindow :: ClientIO Bool
  -- ^ Sends a WINDOW_UPDATE frame crediting it with the whole amount credited
  -- since the last _updateWindow call. The boolean tells whether an update was
  -- actually sent or not. A reason for not sending an update is if there is no
  -- credit in the flow-control system.
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
  , _withdrawCredit :: WindowSize -> ClientIO WindowSize
  -- ^ Wait until we can take credit from stash. The returned value correspond
  -- to the amount that could be withdrawn, which is min(current, wanted). A
  -- caller should withdraw credit to send DATA chunks and put back any unused
  -- credit with _receiveCredit.
  }

-- | Defines a client stream.
--
-- Please red the doc for this record fields and then see 'StreamStarter'.
data StreamDefinition a = StreamDefinition {
    _initStream   :: ClientIO StreamThread
  -- ^ Function to initialize a new client stream. This function runs in a
  -- exclusive-access section of the code and may prevent other threads to
  -- initialize new streams. Hence, you should ensure this IO does not wait for
  -- long periods of time.
  , _handleStream :: IncomingFlowControl -> OutgoingFlowControl -> ClientIO a
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
     (Http2Stream -> StreamDefinition a) -> ClientIO (Either TooMuchConcurrency a)

-- | Whether or not the client library believes the server will reject the new
-- stream. The Int content corresponds to the number of streams that should end
-- before accepting more streams. A reason this number can be more than zero is
-- that servers can change (and hence reduce) the advertised number of allowed
-- 'maxConcurrentStreams' at any time.
newtype TooMuchConcurrency = TooMuchConcurrency { _getStreamRoomNeeded :: Int }
    deriving Show

-- | Record holding functions one can call while in an HTTP2 client session.
data Http2Client = Http2Client {
    _ping             :: ByteString -> ClientIO (ClientIO (FrameHeader, FramePayload))
  -- ^ Send a PING, the payload size must be exactly eight bytes.
  -- Returns an IO to wait for a ping reply. No timeout is provided. Only the
  -- first call to this IO will return if a reply is received. Hence we
  -- recommend wrapping this IO in an Async (e.g., with @race (threadDelay
  -- timeout)@.)
  , _settings         :: SettingsList -> ClientIO (ClientIO (FrameHeader, FramePayload))
  -- ^ Sends a SETTINGS. Returns an IO to wait for a settings reply. No timeout
  -- is provided. Only the first call to this IO will return if a reply is
  -- received. Hence we recommend wrapping this IO in an Async (e.g., with
  -- @race (threadDelay timeout)@.)
  , _goaway           :: ErrorCode -> ByteString -> ClientIO ()
  -- ^ Sends a GOAWAY.
  , _startStream      :: forall a. StreamStarter a
  -- ^ Spawns new streams. See 'StreamStarter'.
  , _incomingFlowControl :: IncomingFlowControl
  -- ^ Simple getter for the 'IncomingFlowControl' for the whole client
  -- connection.
  , _outgoingFlowControl :: OutgoingFlowControl
  -- ^ Simple getter for the 'OutgoingFlowControl' for the whole client
  -- connection.
  , _payloadSplitter :: IO PayloadSplitter
  -- ^ Returns a function to split a payload.
  , _asyncs         :: !Http2ClientAsyncs
  -- ^ Asynchronous operations threads.
  , _close           :: ClientIO ()
  -- ^ Immediately stop processing incoming frames and closes the network
  -- connection.
  }

data InitHttp2Client = InitHttp2Client {
    _initPing                :: ByteString -> ClientIO (ClientIO (FrameHeader, FramePayload))
  , _initSettings            :: SettingsList -> ClientIO (ClientIO (FrameHeader, FramePayload))
  , _initGoaway              :: ErrorCode -> ByteString -> ClientIO ()
  , _initStartStream         :: forall a. StreamStarter a
  , _initIncomingFlowControl :: IncomingFlowControl
  , _initOutgoingFlowControl :: OutgoingFlowControl
  , _initPaylodSplitter      :: IO PayloadSplitter
  , _initClose               :: ClientIO ()
  -- ^ Immediately closes the connection.
  , _initStop                :: ClientIO Bool
  -- ^ Stops receiving frames.
  }

-- | Set of Async threads running an Http2Client.
--
-- This asyncs are linked to the thread where the Http2Client is created.
-- If you modify this structure to add more Async, please also modify
-- 'linkAsyncs' accordingly.
data Http2ClientAsyncs = Http2ClientAsyncs {
    _waitSettingsAsync   :: Async (Either ClientError (FrameHeader, FramePayload))
  -- ^ Async waiting for the initial settings ACK.
  , _incomingFramesAsync :: Async (Either ClientError ())
  -- ^ Async responsible for ingesting all frames, increasing the
  -- maximum-received streamID and starting the frame dispatch. See
  -- 'dispatchFrames'.
  }

-- | Links all client's asyncs to current thread using:
-- @ link someUnderlyingAsync @ .
linkAsyncs :: Http2Client -> ClientIO ()
linkAsyncs client =
    let Http2ClientAsyncs{..} = _asyncs client in do
            link _waitSettingsAsync
            link _incomingFramesAsync

-- | Synonym of '_goaway'.
--
-- https://github.com/http2/http2-spec/pull/366
_gtfo :: Http2Client -> ErrorCode -> ByteString -> ClientIO ()
_gtfo = _goaway

-- | Opaque proof that a client stream was initialized.
--
-- This type is only useful to force calling '_headers' in '_initStream' and
-- contains no information.
data StreamThread = CST

-- | Record holding functions one can call while in an HTTP2 client stream.
data Http2Stream = Http2Stream {
    _headers      :: HPACK.HeaderList
                  -> (FrameFlags -> FrameFlags)
                  -> ClientIO StreamThread
  -- ^ Starts the stream with HTTP headers. Flags modifier can use
  -- 'setEndStream' if no data is required passed the last block of headers.
  -- Usually, this is the only call needed to build an '_initStream'.
  , _prio         :: Priority -> ClientIO ()
  -- ^ Changes the PRIORITY of this stream.
  , _rst          :: ErrorCode -> ClientIO ()
  -- ^ Resets this stream with a RST frame. You should not use this stream past this call.
  , _waitEvent    :: ClientIO StreamEvent
  -- ^ Waits for the next event on the stream.
  , _sendDataChunk     :: (FrameFlags -> FrameFlags) -> ByteString -> ClientIO ()
  -- ^ Sends a DATA frame chunk. You can use send empty frames with only
  -- headers modifiers to close streams. This function is oblivious to framing
  -- and hence does not respect the RFC if sending large blocks. Use 'sendData'
  -- to chunk and send naively according to server\'s preferences. This function
  -- can be useful if you intend to handle the framing yourself.
  , _handlePushPromise :: StreamId -> HeaderList -> PushPromiseHandler -> ClientIO ()
  }

-- | Sends HTTP trailers.
--
-- Trailers should be the last thing sent over a stream.
trailers :: Http2Stream -> HPACK.HeaderList -> (FrameFlags -> FrameFlags) -> ClientIO ()
trailers stream hdrs flagmod = void $ _headers stream hdrs flagmod

-- | Handler upon receiving a PUSH_PROMISE from the server.
--
-- The functions for 'Http2Stream' are similar to those used in ''. But callers
-- shall not use '_headers' to initialize the PUSH_PROMISE stream. Rather,
-- callers should 'waitHeaders' or '_rst' to reject the PUSH_PROMISE.
--
-- The StreamId corresponds to the parent stream as PUSH_PROMISEs are tied to a
-- client-initiated stream. Longer term we may move passing this handler to the
-- '_startStream' instead of 'newHttp2Client' (as it is for now).
type PushPromiseHandler =
    StreamId -> Http2Stream -> HeaderList -> IncomingFlowControl -> OutgoingFlowControl -> ClientIO ()

-- | Starts a new stream (i.e., one HTTP request + server-pushes).
--
-- You will typically call the returned 'StreamStarter' immediately to define
-- what you want to do with the Http2Stream.
--
-- @ _ <- (withHttp2Stream myClient $ \stream -> StreamDefinition _ _) @
--
-- Please refer to 'StreamStarter' and 'StreamDefinition' for more.
withHttp2Stream :: Http2Client -> StreamStarter a
withHttp2Stream client = _startStream client

-- | Type synonym for functions that modify flags.
--
-- Typical FlagSetter for library users are HTTP2.setEndHeader when sending
-- headers HTTP2.setEndStream to signal that there the client is not willing to
-- send more data.
--
-- We might use Endo in the future.
type FlagSetter = FrameFlags -> FrameFlags

-- | Sends the HTTP2+HTTP headers of your chosing.
--
-- You must add HTTP2 pseudo-headers first, followed by your typical HTTP
-- headers. This function makes no verification of this
-- ordering/exhaustinevess.
--
-- HTTP2 pseudo-headers replace the HTTP verb + parsed url as follows:
-- ":method" such as "GET",
-- ":scheme" such as "https",
-- ":path" such as "/blog/post/1234?foo=bar",
-- ":authority" such as "haskell.org"
--
-- Note that we currently enforce the 'HTTP2.setEndHeader' but this design
-- choice may change in the future. Hence, we recommend you use
-- 'HTTP2.setEndHeader' as well.
headers :: Http2Stream -> HeaderList -> FlagSetter -> ClientIO StreamThread
headers = _headers

-- | Starts a new Http2Client around a frame connection.
--
-- This function is slightly safer than 'startHttp2Client' because it uses
-- 'Control.Concurrent.Async.withAsync' instead of
-- 'Control.Concurrent.Async.async'; plus this function calls 'linkAsyncs' to
-- make sure that a network error kills the controlling thread. However, this
-- with-pattern takes the control of the thread and can be annoying at times.
--
-- This function tries to finalize the client with a call to `_close`, a second
-- call to `_close` will trigger an IOException because the Handle representing
-- the TCP connection will be closed.
runHttp2Client
  :: Http2FrameConnection
  -- ^ A frame connection.
  -> Int
  -- ^ The buffersize for the Network.HPACK encoder.
  -> Int
  -- ^ The buffersize for the Network.HPACK decoder.
  -> SettingsList
  -- ^ Initial SETTINGS that are sent as first frame.
  -> GoAwayHandler
  -- ^ Actions to run when the remote sends a GoAwayFrame
  -> FallBackFrameHandler
  -- ^ Actions to run when a control frame is not yet handled in http2-client
  -- lib (e.g., PRIORITY frames).
  -> (Http2Client -> ClientIO a)
  -- ^ Actions to run on the client.
  -> ClientIO a
runHttp2Client conn encoderBufSize decoderBufSize initSettings goAwayHandler fallbackHandler mainHandler = do
    (incomingLoop, initClient) <- initHttp2Client conn encoderBufSize decoderBufSize goAwayHandler fallbackHandler
    withAsync incomingLoop $ \aIncoming -> do
        settsIO <- _initSettings initClient initSettings
        withAsync settsIO $ \aSettings -> do
            let client = Http2Client {
              _settings            = _initSettings initClient
            , _ping                = _initPing initClient
            , _goaway              = _initGoaway initClient
            , _close               =
                _initStop initClient >> _initClose initClient
            , _startStream         = _initStartStream initClient
            , _incomingFlowControl = _initIncomingFlowControl initClient
            , _outgoingFlowControl = _initOutgoingFlowControl initClient
            , _payloadSplitter     = _initPaylodSplitter initClient
            , _asyncs              = Http2ClientAsyncs aSettings aIncoming
            }
            linkAsyncs client
            ret <- mainHandler client
            _close client
            return ret

-- | Starts a new Http2Client around a frame connection.
--
-- You may want to 'linkAsyncs' for a proper and automated cleanup of the
-- underlying threads.
newHttp2Client
  :: Http2FrameConnection
  -- ^ A frame connection.
  -> Int
  -- ^ The buffersize for the Network.HPACK encoder.
  -> Int
  -- ^ The buffersize for the Network.HPACK decoder.
  -> SettingsList
  -- ^ Initial SETTINGS that are sent as first frame.
  -> GoAwayHandler
  -- ^ Actions to run when the remote sends a GoAwayFrame
  -> FallBackFrameHandler
  -- ^ Actions to run when a control frame is not yet handled in http2-client
  -- lib (e.g., PRIORITY frames).
  -> ClientIO Http2Client
newHttp2Client conn encoderBufSize decoderBufSize initSettings goAwayHandler fallbackHandler = do
    (incomingLoop, initClient) <- initHttp2Client conn encoderBufSize decoderBufSize goAwayHandler fallbackHandler
    aIncoming <- async incomingLoop
    settsIO <- _initSettings initClient initSettings
    aSettings <- async settsIO
    return $ Http2Client {
        _settings            = _initSettings initClient
      , _ping                = _initPing initClient
      , _goaway              = _initGoaway initClient
      , _close               =
          _initStop initClient >> _initClose initClient
      , _startStream         = _initStartStream initClient
      , _incomingFlowControl = _initIncomingFlowControl initClient
      , _outgoingFlowControl = _initOutgoingFlowControl initClient
      , _payloadSplitter     = _initPaylodSplitter initClient
      , _asyncs              = Http2ClientAsyncs aSettings aIncoming
      }

initHttp2Client
  :: Http2FrameConnection
  -> Int
  -> Int
  -> GoAwayHandler
  -> FallBackFrameHandler
  -> ClientIO (ClientIO (), InitHttp2Client)
initHttp2Client conn encoderBufSize decoderBufSize goAwayHandler fallbackHandler = do
    let controlStream = makeFrameClientStream conn 0
    let ackPing = sendPingFrame controlStream HTTP2.setAck
    let ackSettings = sendSettingsFrame controlStream HTTP2.setAck []

    {- Setup for initial thread receiving server frames. -}
    dispatch  <- newDispatchIO
    dispatchControl <- newDispatchControlIO encoderBufSize
                                            ackPing
                                            ackSettings
                                            goAwayHandler
                                            fallbackHandler

    let baseIncomingWindowSize = initialWindowSize . _clientSettings <$> readSettings dispatchControl
        baseOutgoingWindowSize = initialWindowSize . _serverSettings <$> readSettings dispatchControl
    _initIncomingFlowControl <- lift $ newIncomingFlowControl dispatchControl baseIncomingWindowSize (sendWindowUpdateFrame controlStream)
    windowUpdatesChan <- newChan
    _initOutgoingFlowControl <- lift $ newOutgoingFlowControl dispatchControl windowUpdatesChan baseOutgoingWindowSize

    dispatchHPACK <- newDispatchHPACKIO decoderBufSize
    (incomingLoop,endIncomingLoop) <- dispatchLoop conn dispatch dispatchControl windowUpdatesChan _initIncomingFlowControl dispatchHPACK

    {- Setup for client-initiated streams. -}
    conccurentStreams <- newIORef 0
    -- prepare client streams
    clientStreamIdMutex <- newMVar 0
    let withClientStreamId h = bracket (takeMVar clientStreamIdMutex)
            (putMVar clientStreamIdMutex . succ)
            (\k -> h (2 * k + 1)) -- Note: client StreamIds MUST be odd

    let _initStartStream getWork = do
            maxConcurrency <- fromMaybe 100 . maxConcurrentStreams . _serverSettings <$> readSettings dispatchControl
            roomNeeded <- atomicModifyIORef' conccurentStreams
                (\n -> if n < maxConcurrency then (n + 1, 0) else (n, 1 + n - maxConcurrency))
            if roomNeeded > 0
            then
                return $ Left $ TooMuchConcurrency roomNeeded
            else Right <$> do
                windowUpdatesChan <- newChan
                cont <- withClientStreamId $ \sid -> do
                    dispatchStream <- newDispatchStreamIO sid
                    initializeStream conn
                                     dispatch
                                     dispatchControl
                                     dispatchStream
                                     windowUpdatesChan
                                     getWork
                                     Idle
                v <- cont
                atomicModifyIORef' conccurentStreams (\n -> (n - 1, ()))
                pure v

    let _initPing dat = do
            handler <- lift $ registerPingHandler dispatchControl dat
            sendPingFrame controlStream id dat
            return $ lift $ waitPingReply handler

    let _initSettings settslist = do
            handler <- lift $ registerSetSettingsHandler dispatchControl
            sendSettingsFrame controlStream id settslist
            return $ do
                ret <- lift $ waitSetSettingsReply handler
                modifySettings dispatchControl
                    (\(ConnectionSettings cli srv) ->
                        (ConnectionSettings (HTTP2.updateSettings cli settslist) srv, ()))
                return ret
    let _initGoaway err errStr = do
            sId <- lift $ readMaxReceivedStreamIdIO dispatch
            sendGTFOFrame controlStream sId err errStr

    let _initPaylodSplitter = settingsPayloadSplitter <$> readSettings dispatchControl

    let _initStop = endIncomingLoop

    let _initClose = closeConnection conn

    return (incomingLoop, InitHttp2Client{..})

initializeStream
  :: Http2FrameConnection
  -> Dispatch
  -> DispatchControl
  -> DispatchStream
  -> Chan (FrameHeader, FramePayload)
  -> (Http2Stream -> StreamDefinition a)
  -> StreamFSMState
  -> ClientIO (ClientIO a)
initializeStream conn dispatch control stream windowUpdatesChan getWork initialState = do
    let sid = _dispatchStreamId stream
    let frameStream = makeFrameClientStream conn sid

    let events        = _dispatchStreamReadEvents stream

    -- Prepare handlers.
    let _headers headersList flags = do
            splitter <- settingsPayloadSplitter <$> readSettings control
            cst <- sendHeaders frameStream (_dispatchControlHpackEncoder control) headersList splitter flags
            when (testEndStream $ flags 0) $ do
                closeLocalStream dispatch sid
            return cst
    let _waitEvent    = readChan events
    let _sendDataChunk flags dat = do
            sendDataFrame frameStream flags dat
            when (testEndStream $ flags 0) $ do
                closeLocalStream dispatch sid
    let _rst = \err -> do
            sendResetFrame frameStream err
            closeReleaseStream dispatch sid
    let _prio           = sendPriorityFrame frameStream
    let _handlePushPromise ppSid ppHeaders ppHandler = do
            let mkStreamActions s = StreamDefinition (return CST) (ppHandler sid s ppHeaders)
            newStream <- newDispatchStreamIO ppSid
            ppWindowsUpdatesChan <- newChan
            ppCont <- initializeStream conn
                                       dispatch
                                       control
                                       newStream
                                       ppWindowsUpdatesChan
                                       mkStreamActions
                                       ReservedRemote
            ppCont

    let streamActions = getWork $ Http2Stream{..}

    -- Register handlers for receiving frames and perform the 1st action, the
    -- stream won't be idle anymore.
    registerStream dispatch sid (StreamState windowUpdatesChan events initialState)
    _ <- _initStream streamActions

    -- Returns 2nd action.
    -- We build the flow control contexts in this action outside the exclusive
    -- lock on clientStreamIdMutex will be released.
    return $ do
        let baseIncomingWindowSize = initialWindowSize . _clientSettings <$> readSettings control
        isfc <- lift $ newIncomingFlowControl control baseIncomingWindowSize (sendWindowUpdateFrame frameStream)
        let baseOutgoingWindowSize = initialWindowSize . _serverSettings <$> readSettings control
        osfc <- lift $ newOutgoingFlowControl control windowUpdatesChan baseOutgoingWindowSize
        _handleStream streamActions isfc osfc

dispatchLoop
  :: Http2FrameConnection
  -> Dispatch
  -> DispatchControl
  -> Chan (FrameHeader, FramePayload)
  -> IncomingFlowControl
  -> DispatchHPACK
  -> ClientIO (ClientIO (), ClientIO Bool)
dispatchLoop conn d dc windowUpdatesChan inFlowControl dh = do
    let getNextFrame = next conn
    let go = delayException . forever $ do
            frame <- getNextFrame
            dispatchFramesStep frame d
            whenFrame (hasStreamId 0) frame $ \got ->
                dispatchControlFramesStep windowUpdatesChan got dc
            whenFrame (hasTypeId [FrameData]) frame $ \got ->
                creditDataFramesStep d inFlowControl got
            whenFrame (hasTypeId [FrameWindowUpdate]) frame $ \got -> do
                updateWindowsStep d got
            whenFrame (hasTypeId [FramePushPromise, FrameHeaders]) frame $ \got -> do
                let hpackLoop (FinishedWithHeaders curFh sId mkNewHdrs) = lift $ do
                        newHdrs <- mkNewHdrs
                        chan <- fmap _streamStateEvents <$> lookupStreamState d sId
                        let msg = StreamHeadersEvent curFh newHdrs
                        maybe (return ()) (flip writeChan msg) chan
                    hpackLoop (FinishedWithPushPromise curFh parentSid newSid mkNewHdrs) = lift $ do
                        newHdrs <- mkNewHdrs
                        chan <- fmap _streamStateEvents <$> lookupStreamState d parentSid
                        let msg = StreamPushPromiseEvent curFh newSid newHdrs
                        maybe (return ()) (flip writeChan msg) chan
                    hpackLoop (WaitContinuation act)        =
                        getNextFrame >>= act >>= hpackLoop
                    hpackLoop (FailedHeaders curFh sId err)        = lift $ do
                        chan <- fmap _streamStateEvents <$> lookupStreamState d sId
                        let msg = StreamErrorEvent curFh err
                        maybe (return ()) (flip writeChan msg) chan
                hpackLoop (dispatchHPACKFramesStep got dh)
            whenFrame (hasTypeId [FrameRSTStream]) frame $ \got -> do
                handleRSTStep d got
            finalizeFramesStep frame d
    end <- newEmptyMVar
    let run = void $ race go (takeMVar end)
    let stop = tryPutMVar end ()
    return (run, stop)

handleRSTStep
  :: Dispatch
  -> (FrameHeader, FramePayload)
  -> ClientIO ()
handleRSTStep d (fh, payload) = do
    let sid = streamId fh
    case payload of
        (RSTStreamFrame err) -> lift $ do
            chan <- fmap _streamStateEvents <$> lookupStreamState d sid
            let msg = StreamErrorEvent fh (HTTP2.fromErrorCode err)
            maybe (return ()) (flip writeChan msg) chan
            closeReleaseStream d sid
        _ ->
            error $ "expecting RSTFrame but got " ++ show payload

dispatchFramesStep
  :: (FrameHeader, Either FrameDecodeError FramePayload)
  -> Dispatch
  -> ClientIO ()
dispatchFramesStep (fh,_) d = do
    let sid = streamId fh
    -- Remember highest streamId.
    atomicModifyIORef' (_dispatchMaxStreamId d) (\n -> (max n sid, ()))

finalizeFramesStep
  :: (FrameHeader, Either FrameDecodeError FramePayload)
  -> Dispatch
  -> ClientIO ()
finalizeFramesStep (fh,_) d = do
    let sid = streamId fh
    -- Remote-close streams that match.
    when (testEndStream $ flags fh) $ do
        closeRemoteStream d sid

dispatchControlFramesStep
  :: Chan (FrameHeader, FramePayload)
  -> (FrameHeader, FramePayload)
  -> DispatchControl
  -> ClientIO ()
dispatchControlFramesStep windowUpdatesChan controlFrame@(fh, payload) control@(DispatchControl{..}) = do
    case payload of
        (SettingsFrame settsList)
            | not . testAck . flags $ fh -> do
                atomicModifyIORef' _dispatchControlConnectionSettings
                                   (\(ConnectionSettings cli srv) ->
                                      (ConnectionSettings cli (HTTP2.updateSettings srv settsList), ()))
                lift $ maybe (return ())
                      (_applySettings _dispatchControlHpackEncoder)
                      (lookup SettingsHeaderTableSize settsList)
                _dispatchControlAckSettings
            | otherwise                 -> do
                handler <- lookupAndReleaseSetSettingsHandler control
                maybe (return ()) (notifySetSettingsHandler controlFrame) handler
        (PingFrame pingMsg)
            | not . testAck . flags $ fh ->
                _dispatchControlAckPing pingMsg
            | otherwise                 -> do
                handler <- lookupAndReleasePingHandler control pingMsg
                maybe (return ()) (notifyPingHandler controlFrame) handler
        (WindowUpdateFrame _ )  ->
                writeChan windowUpdatesChan controlFrame
        (GoAwayFrame lastSid errCode reason)  ->
             _dispatchControlOnGoAway $ RemoteSentGoAwayFrame lastSid errCode reason

        _                   ->
             _dispatchControlOnFallback controlFrame

-- | We currently need a specific step in the main loop for crediting streams
-- because a client user may programmatically reset and stop listening for a
-- stream and stop calling waitData (which credits streams).
--
-- TODO: modify the '_rst' function to wait and credit all the remaining data
-- that could have been sent in flight
creditDataFramesStep
  :: Dispatch
  -> IncomingFlowControl
  -> (FrameHeader, FramePayload)
  -> ClientIO ()
creditDataFramesStep d flowControl (fh,payload) = do
    -- TODO: error if detect over-run. Current implementation credits
    -- everything back. Hence, over-run should never happen.
    _ <- lift $ _consumeCredit flowControl (HTTP2.payloadLength fh)
    lift $ _addCredit flowControl (HTTP2.payloadLength fh)

    -- Write to the interested streams.
    let sid = streamId fh
    case payload of
        (DataFrame dat) -> do
            chan <- fmap _streamStateEvents <$> lookupStreamState d sid
            maybe (return ()) (flip writeChan $ StreamDataEvent fh dat) chan
        _ ->
            error $ "expecting DataFrame but got " ++ show payload

updateWindowsStep
  :: Dispatch
  -> (FrameHeader, FramePayload)
  -> ClientIO ()
updateWindowsStep d got@(fh,_) = do
    let sid = HTTP2.streamId fh
    chan <- fmap _streamStateWindowUpdatesChan <$> lookupStreamState d sid
    maybe (return ()) (flip writeChan got) chan --TODO: refer to RFC for erroring on idle/closed streams

data HPACKLoopDecision =
    ForwardHeader !StreamId
  | OpenPushPromise !StreamId !StreamId

data HPACKStepResult =
    WaitContinuation !((FrameHeader, Either FrameDecodeError FramePayload) -> ClientIO HPACKStepResult)
  | FailedHeaders !FrameHeader !StreamId ErrorCode
  | FinishedWithHeaders !FrameHeader !StreamId (IO HeaderList)
  | FinishedWithPushPromise !FrameHeader !StreamId !StreamId (IO HeaderList)

dispatchHPACKFramesStep
  :: (FrameHeader, FramePayload)
  -> DispatchHPACK
  -> HPACKStepResult
dispatchHPACKFramesStep (fh,fp) (DispatchHPACK{..}) =
    let (decision, pattern) = case fp of
            PushPromiseFrame ppSid hbf -> do
                (OpenPushPromise sid ppSid, Right hbf)
            HeadersFrame _ hbf       -> -- TODO: handle priority
                (ForwardHeader sid, Right hbf)
            RSTStreamFrame err       ->
                (ForwardHeader sid, Left err)
            _                        ->
                error "wrong TypeId"
    in go fh decision pattern
  where
    sid :: StreamId
    sid = HTTP2.streamId fh

    go :: FrameHeader -> HPACKLoopDecision -> Either ErrorCode ByteString -> HPACKStepResult
    go curFh decision (Right buffer) =
        if not $ HTTP2.testEndHeader (HTTP2.flags curFh)
        then WaitContinuation $ \frame -> do
            let interrupted fh2 fp2 =
                    not $ hasTypeId [ FrameRSTStream , FrameContinuation ] fh2 fp2
            whenFrameElse interrupted frame (\_ ->
                error "invalid frame type while waiting for CONTINUATION")
                                            (\(lastFh, lastFp) ->
                case lastFp of
                    ContinuationFrame chbf ->
                        return $ go lastFh decision (Right (ByteString.append buffer chbf))
                    RSTStreamFrame err     ->
                        return $ go lastFh decision (Left err)
                    _                     ->
                        error "continued frame has invalid type")
        else case decision of
            ForwardHeader sId ->
                FinishedWithHeaders curFh sId (decodeHeader _dispatchHPACKDynamicTable buffer)
            OpenPushPromise parentSid newSid ->
                FinishedWithPushPromise curFh parentSid newSid (decodeHeader _dispatchHPACKDynamicTable buffer)
    go curFh _ (Left err) =
        FailedHeaders curFh sid (HTTP2.fromErrorCode err)


newIncomingFlowControl
  :: DispatchControl
  -> IO Int
  -- ^ Action to get the base window size.
  -> (WindowSize -> ClientIO ())
  -- ^ Action to send the window update to the server.
  -> IO IncomingFlowControl
newIncomingFlowControl control getBase doSendUpdate = do
    creditAdded <- newIORef 0
    creditConsumed <- newIORef 0
    let _addCredit n = atomicModifyIORef' creditAdded (\c -> (c + n, ()))
    let _consumeCredit n = do
            conso <- atomicModifyIORef' creditConsumed (\c -> (c + n, c + n))
            base <- getBase
            extra <- readIORef creditAdded
            return $ base + extra - conso
    let _updateWindow = do
            base <- initialWindowSize . _clientSettings <$> readSettings control
            added <- readIORef creditAdded
            consumed <- readIORef creditConsumed

            let transferred = min added (HTTP2.maxWindowSize - base + consumed)
            let shouldUpdate = transferred > 0

            _addCredit (negate transferred)
            _ <- lift $ _consumeCredit (negate transferred)
            when shouldUpdate (doSendUpdate transferred)

            return shouldUpdate
    return $ IncomingFlowControl _addCredit _consumeCredit _updateWindow

newOutgoingFlowControl ::
     DispatchControl
  -- ^ Control dispatching reference.
  -> Chan (FrameHeader, FramePayload)
  -> IO Int
  -- ^ Action to get the instantaneous base window-size.
  -> IO OutgoingFlowControl
newOutgoingFlowControl control frames getBase = do
    credit <- newIORef 0
    let receive n = atomicModifyIORef' credit (\c -> (c + n, ()))
    let withdraw 0 = return 0
        withdraw n = do
            base <- lift getBase
            got <- atomicModifyIORef' credit (\c ->
                    if base + c >= n
                    then (c - n, n)
                    else (0 - base, base + c))
            if got > 0
            then return got
            else do
                amount <- race (waitSettingsChange base) (waitSomeCredit frames)
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
            new <- initialWindowSize . _serverSettings <$> readSettings control
            if new == prev then threadDelay 1000000 >> waitSettingsChange prev else return ()
    waitSomeCredit frames = do
        got <- readChan frames
        case got of
            (_, WindowUpdateFrame amt) ->
                return amt
            _                         ->
                error "got forwarded an unknown frame"

sendHeaders
  :: Http2FrameClientStream
  -> HpackEncoderContext
  -> HeaderList
  -> PayloadSplitter
  -> (FrameFlags -> FrameFlags)
  -> ClientIO StreamThread
sendHeaders s enc hdrs blockSplitter flagmod = do
    _sendFrames s (lift mkFrames)
    return CST
  where
    mkFrames = do
        headerBlockFragments <- blockSplitter <$> _encodeHeaders enc hdrs
        let framers           = (HeadersFrame Nothing) : repeat ContinuationFrame
        let frames            = zipWith ($) framers headerBlockFragments
        let modifiersReversed = (HTTP2.setEndHeader . flagmod) : repeat id
        let arrangedFrames    = reverse $ zip modifiersReversed (reverse frames)
        return arrangedFrames

-- | A function able to split a header block into multiple fragments.
type PayloadSplitter = ByteString -> [ByteString]

-- | Split headers like so that no payload exceeds server's maxFrameSize.
settingsPayloadSplitter :: ConnectionSettings -> PayloadSplitter
settingsPayloadSplitter (ConnectionSettings _ srv) =
    fixedSizeChunks (maxFrameSize srv)

-- | Breaks a ByteString into fixed-sized chunks.
--
-- @ fixedSizeChunks 2 "hello" = ["he", "ll", "o"] @
fixedSizeChunks :: Int -> ByteString -> [ByteString]
fixedSizeChunks 0   _    = error "cannot chunk by zero-length blocks"
fixedSizeChunks _   ""   = []
fixedSizeChunks len bstr =
      let
        (chunk, rest) = ByteString.splitAt len bstr
      in
        chunk : fixedSizeChunks len rest

-- | Sends data, chunked according to the server's preferred chunk size.
--
-- This function does not respect HTTP2 flow-control and send chunks
-- sequentially. Hence, you should first ensure that you have enough
-- flow-control credit (with '_withdrawCredit') or risk a connection failure.
-- When you call _withdrawCredit keep in mind that HTTP2 has flow control at
-- the stream and at the connection level. If you use `http2-client` in a
-- multithreaded conext, you should avoid starving the connection-level
-- flow-control.
--
-- If you want to send bytestrings that fit in RAM, you can use
-- 'Network.HTTP2.Client.Helpers.upload' as a function that implements
-- flow-control.
--
-- This function does not send frames back-to-back, that is, other frames may
-- get interleaved between two chunks (for instance, to give priority to other
-- streams, although no priority queue exists in `http2-client` so far).
--
-- Please refer to '_sendDataChunk' and '_withdrawCredit' as well.
sendData :: Http2Client -> Http2Stream -> FlagSetter -> ByteString -> ClientIO ()
sendData conn stream flagmod dat = do
    splitter <- lift  $ _payloadSplitter conn
    let chunks = splitter dat
    let pairs  = reverse $ zip (flagmod : repeat id) (reverse chunks)
    when (null chunks) $ _sendDataChunk stream flagmod ""
    forM_ pairs $ \(flags, chunk) -> _sendDataChunk stream flags chunk

sendDataFrame
  :: Http2FrameClientStream
  -> (FrameFlags -> FrameFlags) -> ByteString -> ClientIO ()
sendDataFrame s flagmod dat = do
    sendOne s flagmod (DataFrame dat)

sendResetFrame :: Http2FrameClientStream -> ErrorCode -> ClientIO ()
sendResetFrame s err = do
    sendOne s id (RSTStreamFrame err)

sendGTFOFrame
  :: Http2FrameClientStream
     -> StreamId -> ErrorCode -> ByteString -> ClientIO ()
sendGTFOFrame s lastStreamId err errStr = do
    sendOne s id (GoAwayFrame lastStreamId err errStr)

rfcError :: String -> a
rfcError msg = error (msg ++ "draft-ietf-httpbis-http2-17")

sendPingFrame
  :: Http2FrameClientStream
  -> (FrameFlags -> FrameFlags)
  -> ByteString
  -> ClientIO ()
sendPingFrame s flags dat
  | _getStreamId s /= 0        =
        rfcError "PING frames are not associated with any individual stream."
  | ByteString.length dat /= 8 =
        rfcError "PING frames MUST contain 8 octets"
  | otherwise                  = sendOne s flags (PingFrame dat)

sendWindowUpdateFrame
  :: Http2FrameClientStream -> WindowSize -> ClientIO ()
sendWindowUpdateFrame s amount = do
    let payload = WindowUpdateFrame amount
    sendOne s id payload
    return ()

sendSettingsFrame
  :: Http2FrameClientStream
     -> (FrameFlags -> FrameFlags) -> SettingsList -> ClientIO ()
sendSettingsFrame s flags setts
  | _getStreamId s /= 0        =
        rfcError "The stream identifier for a SETTINGS frame MUST be zero (0x0)."
  | otherwise                  = do
    let payload = SettingsFrame setts
    sendOne s flags payload
    return ()

sendPriorityFrame :: Http2FrameClientStream -> Priority -> ClientIO ()
sendPriorityFrame s p = do
    let payload = PriorityFrame p
    sendOne s id payload
    return ()

-- | Runs an action, rethrowing exception 50ms later.
--
-- In a context where asynchronous are likely to occur this function gives a
-- chance to other threads to do some work before Async linking reaps them all.
--
-- In particular, servers are likely to close their TCP connection soon after
-- sending a GoAwayFrame and we want to give a better chance to clients to
-- observe the GoAwayFrame in their handlers to distinguish GoAwayFrames
-- followed by TCP disconnection and plain TCP resets. As a result, this
-- function is mostly used to delay 'dispatchFrames'. A more involved
-- and future design will be to inline the various loop-processes for
-- dispatchFrames and GoAwayHandlers in a same thread (e.g., using
-- pipe/conduit to retain composability).
delayException :: ClientIO a -> ClientIO a
delayException act = act `catch` slowdown
  where
    slowdown :: SomeException -> ClientIO a
    slowdown e = threadDelay 50000 >> throwIO e

