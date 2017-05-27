{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards  #-}
{-# LANGUAGE RankNTypes  #-}

-- TODO: improve on received frame resources
-- * bounded channels
-- * do not broadcast to every chan but filter upfront with a lookup
-- TODO: improve on long-standing stream
-- * allow to reconnect behind the scene when Ids are almost exhausted
module Network.HTTP2.Client (
      Http2Client
    , newHttp2Client
    , newHpackEncoder
    , startStream
    , flowControl
    , Http2ClientStream(..)
    , StreamActions(..)
    , FlowControl(..)
    , module Network.HTTP2.Client.FrameConnection
    ) where

import           Control.Exception (bracket)
import           Control.Concurrent.MVar (newMVar, takeMVar, putMVar)
import           Control.Concurrent (forkIO, threadDelay, killThread)
import           Control.Concurrent.Chan (newChan, dupChan, readChan, writeChan)
import           Control.Monad (forever, when)
import           Data.ByteString (ByteString)
import           Data.IORef (newIORef, atomicModifyIORef')
import           Network.HPACK as HTTP2
import           Network.HTTP2 as HTTP2

import           Network.HTTP2.Client.FrameConnection

newtype HpackEncoder =
    HpackEncoder { encodeHeaders :: HeaderList -> IO HTTP2.HeaderBlockFragment }

data StreamActions a = StreamActions {
    _initStream   :: IO ClientStreamThread
  , _handleStream :: FlowControl -> IO a -- TODO: create a FlowControl object holding continuations to update/send window-updates (maybe protect from sending after closing a stream?)
  }

data FlowControl = FlowControl {
    _creditFlow   :: WindowSize -> IO ()
  -- TODO: , _updateWindow :: IO ()
  }

type StreamStarter a =
     HpackEncoder
  -> (Http2ClientStream -> StreamActions a)
  -> IO a

data Http2Client = Http2Client {
    _newHpackEncoder  :: IO HpackEncoder
  , _startStream      :: forall a. StreamStarter a
  , _flowControl      :: FlowControl
  }

newHpackEncoder = _newHpackEncoder
startStream = _startStream
flowControl = _flowControl

-- | Proof that a client stream was initialized.
data ClientStreamThread = CST

data Http2ClientStream = Http2ClientStream {
    _headersFrame       :: HTTP2.HeaderList -> IO ClientStreamThread
  , _waitFrame          :: IO (HTTP2.FrameHeader, Either HTTP2.HTTP2Error HTTP2.FramePayload)
  }

newHttp2Client host port tlsParams = do
    -- network connection
    conn <- newHttp2FrameConnection "127.0.0.1" 3000 tlsParams

    -- prepare client streams
    clientStreamIdMutex <- newMVar 0
    let withClientStreamId h = bracket
            (takeMVar clientStreamIdMutex)
            (putMVar clientStreamIdMutex . succ)
            (\k -> h (2 * k + 1)) -- client StreamIds MUST be odd

    let controlStream = makeFrameClientStream conn 0

    -- prepare server streams
    serverFrames <- newChan
    _ <- forkIO $ forever (next conn >>= writeChan serverFrames)

    _ <- forkIO $ forever $ do
            controlFrame <- waitFrame 0 serverFrames
            print controlFrame

    let newEncoder = do
            let strategy = (HTTP2.defaultEncodeStrategy { HTTP2.useHuffman = True })
                bufsize  = 4096
            dt <- HTTP2.newDynamicTableForEncoding HTTP2.defaultDynamicTableSize
            return $ HpackEncoder $ HTTP2.encodeHeader strategy bufsize dt

    (_, creditConn) <- newPeriodicRefreshAllCredit controlStream

    let startStream encoder getWork = do
            serverStreamFrames <- dupChan serverFrames
            cont <- withClientStreamId $ \sid -> do
                let frameStream = makeFrameClientStream conn sid
                let _waitFrame = waitFrame sid serverStreamFrames
                let _headersFrame = headersFrame frameStream encoder
                let StreamActions{..} = getWork $ Http2ClientStream{..}
                -- Perform the 1st action, the stream won't be idle anymore.
                _ <- _initStream
                -- Returns a continuation that will spawn a thread to upgrade
                -- the credit on a stream. We need to make sure the
                -- congestion-control thread is dead so we bracket the
                -- caller-specified actions.
                -- TODO: consider using and linking asyncs instead?
                let next = bracket (newPeriodicRefreshAllCredit frameStream)
                                   (killThread . fst)
                                   (_handleStream . snd)
                return next
            cont

    return $ Http2Client newEncoder startStream creditConn

newPeriodicRefreshAllCredit stream = do
    let maxCredit = HTTP2.maxWindowSize - HTTP2.defaultInitialWindowSize
    flowControlCredit <- newIORef maxCredit
    thread <- forkIO $ forever $ do
        amount <- atomicModifyIORef' flowControlCredit (\c -> (0, c))
        when (amount > 0) (windowUpdateFrame stream amount)
    let addCredit n = atomicModifyIORef' flowControlCredit (\c -> (c + n,()))
    return (thread, FlowControl addCredit)

headersFrame s enc headers = do
    let eos = HTTP2.setEndStream . HTTP2.setEndHeader
    payload <- HTTP2.HeadersFrame Nothing <$> (encodeHeaders enc headers)
    send s eos payload
    return CST

windowUpdateFrame s amount = do
    let payload = HTTP2.WindowUpdateFrame amount
    send s id payload
    return ()

waitFrame sid chan =
    loop
  where
    loop = do
        pair@(fHead, _) <- readChan chan
        if streamId fHead /= sid
        then loop
        else return pair
