{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards  #-}
{-# LANGUAGE RankNTypes  #-}

module Network.HTTP2.Client (
      Http2Connection
    , newHttp2Connection
    -- * Interact at the Frame level.
    , Http2ClientStream
    , openClientStream
    , send
    , next
    , closeConnection
    ) where

import           Control.Exception (bracket)
import           Control.Concurrent.MVar (newMVar, takeMVar, putMVar)
import           Data.IORef (newIORef, atomicModifyIORef')
import           Network.HTTP2 (FrameHeader(..), FrameFlags, FramePayload, HTTP2Error, encodeInfo, decodeFramePayload)
import qualified Network.HTTP2 as HTTP2
import           Network.Socket (HostName, PortNumber)
import qualified Network.TLS as TLS

import           Network.HTTP2.Client.RawConnection

data Http2Connection = Http2Connection {
    _openClientStream :: forall a. (Http2ClientStream -> IO a) -> IO a
  -- ^ Starts a new client stream.
  , _serverStream     :: Http2ServerStream
  -- ^ Receives frames from a server.
  , _closeConnection  :: IO ()
  -- ^ Function that will close the network connection.
  }

-- | Closes the Http2Connection.
closeConnection :: Http2Connection -> IO ()
closeConnection = _closeConnection

-- | Opens a client stream and give it to a handler.
openClientStream :: Http2Connection -> (forall a. (Http2ClientStream -> IO a) -> IO a)
openClientStream = _openClientStream

data Http2ClientStream = Http2ClientStream {
    _sendFrame :: (FrameFlags -> FrameFlags) -> FramePayload -> IO ()
  -- ^ Sends a frame to the server.
  -- The first argument is a FrameFlags modifier (e.g., to sed the
  -- end-of-stream flag).
  }

-- | Sends a frame to the server.
send :: Http2ClientStream -> (FrameFlags -> FrameFlags) -> FramePayload -> IO ()
send = _sendFrame

data Http2ServerStream = Http2ServerStream {
    _nextHeaderAndFrame :: IO (FrameHeader, Either HTTP2Error FramePayload)
  }

-- | Waits for the next frame from the server.
next :: Http2Connection -> IO (FrameHeader, Either HTTP2Error FramePayload)
next = _nextHeaderAndFrame . _serverStream

-- | Creates a new 'Http2Connection' to a given host.
newHttp2Connection :: HostName
                   -> PortNumber
                   -> TLS.ClientParams
                   -> IO Http2Connection
newHttp2Connection host port params = do
    -- Spawns an HTTP2 connection.
    http2conn <- newRawHttp2Connection host port params

    -- Prepare a local mutable state, this state should never escape the
    -- function's scope. Else it might lead to bugs (e.g.,
    -- https://ro-che.info/articles/2014-07-30-bracket ) 
    clientStreamCounter <- newIORef 0
    writerMutex <- newMVar () 

    let incr n = let m = succ n in (m, m)
        nextInt = atomicModifyIORef' clientStreamCounter incr
        nextClientStreamId = (\k -> 2 * k + 1) <$> nextInt

    let writeProtect io =
            bracket (takeMVar writerMutex) (putMVar writerMutex) (const io)

    -- Define handlers.
    let withClientStream doWork = do
            streamID <- nextClientStreamId
            let putFrame modifyFF frame = writeProtect . _sendRaw http2conn $
                    HTTP2.encodeFrame (encodeInfo modifyFF streamID) frame
            doWork $ Http2ClientStream putFrame

        nextServerFrameChunk = Http2ServerStream $ do
            (fTy, fh@FrameHeader{..}) <- HTTP2.decodeFrameHeader <$> _nextRaw http2conn 9
            let decoder = decodeFramePayload fTy
            -- TODO: consider splitting the iteration here to give a chance to
            -- _not_ decode the frame, or consider lazyness enough.
            let getNextFrame = decoder fh <$> _nextRaw http2conn payloadLength
            nf <- getNextFrame
            return (fh, nf)

        gtfo = _close http2conn

    return $ Http2Connection withClientStream nextServerFrameChunk gtfo
