{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards  #-}
{-# LANGUAGE RankNTypes  #-}

module Network.HTTP2.Client.FrameConnection (
      Http2FrameConnection
    , newHttp2FrameConnection
    -- * Interact at the Frame level.
    , Http2FrameClientStream
    , openFrameClientStream
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

data Http2FrameConnection = Http2FrameConnection {
    _openFrameClientStream :: HTTP2.StreamId -> forall a. (Http2FrameClientStream -> IO a) -> IO a
  -- ^ Starts a new client stream.
  , _serverStream     :: Http2ServerStream
  -- ^ Receives frames from a server.
  , _closeConnection  :: IO ()
  -- ^ Function that will close the network connection.
  }

-- | Closes the Http2FrameConnection abruptly.
closeConnection :: Http2FrameConnection -> IO ()
closeConnection = _closeConnection

-- | Opens a client stream and give it to a handler.
--
-- StreamId should be observed in increasing order at the server side.
-- This module does not ensure this invariant holds.
openFrameClientStream :: Http2FrameConnection
                      -> HTTP2.StreamId
                      -> (forall a. (Http2FrameClientStream -> IO a) -> IO a)
openFrameClientStream = _openFrameClientStream

data Http2FrameClientStream = Http2FrameClientStream {
    _sendFrame :: (FrameFlags -> FrameFlags) -> FramePayload -> IO ()
  -- ^ Sends a frame to the server.
  -- The first argument is a FrameFlags modifier (e.g., to sed the
  -- end-of-stream flag).
  }

-- | Sends a frame to the server.
send :: Http2FrameClientStream -> (FrameFlags -> FrameFlags) -> FramePayload -> IO ()
send = _sendFrame


data Http2ServerStream = Http2ServerStream {
    _nextHeaderAndFrame :: IO (FrameHeader, Either HTTP2Error FramePayload)
  }

-- | Waits for the next frame from the server.
next :: Http2FrameConnection -> IO (FrameHeader, Either HTTP2Error FramePayload)
next = _nextHeaderAndFrame . _serverStream

-- | Creates a new 'Http2FrameConnection' to a given host for a frame-to-frame communication.
newHttp2FrameConnection :: HostName
                        -> PortNumber
                        -> TLS.ClientParams
                        -> IO Http2FrameConnection
newHttp2FrameConnection host port params = do
    -- Spawns an HTTP2 connection.
    http2conn <- newRawHttp2Connection host port params

    -- Prepare a local mutex, this mutex should never escape the
    -- function's scope. Else it might lead to bugs (e.g.,
    -- https://ro-che.info/articles/2014-07-30-bracket ) 
    writerMutex <- newMVar () 

    let writeProtect io =
            bracket (takeMVar writerMutex) (putMVar writerMutex) (const io)

    -- Define handlers.
    let withClientStream streamID doWork = do
            let putFrame modifyFF frame = writeProtect . _sendRaw http2conn $
                    HTTP2.encodeFrame (encodeInfo modifyFF streamID) frame
            doWork $ Http2FrameClientStream putFrame

        nextServerFrameChunk = Http2ServerStream $ do
            (fTy, fh@FrameHeader{..}) <- HTTP2.decodeFrameHeader <$> _nextRaw http2conn 9
            let decoder = decodeFramePayload fTy
            -- TODO: consider splitting the iteration here to give a chance to
            -- _not_ decode the frame, or consider lazyness enough.
            let getNextFrame = decoder fh <$> _nextRaw http2conn payloadLength
            nf <- getNextFrame
            return (fh, nf)

        gtfo = _close http2conn

    return $ Http2FrameConnection withClientStream nextServerFrameChunk gtfo
