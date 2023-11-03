{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE PackageImports #-}

module Network.HTTP2.Client.FrameConnection (
      Http2FrameConnection(..)
    , newHttp2FrameConnection
    , frameHttp2RawConnection
    -- * Interact at the Frame level.
    , Http2ServerStream(..)
    , Http2FrameClientStream(..)
    , makeFrameClientStream
    , sendOne
    , sendBackToBack
    , next
    , closeConnection
    ) where

import           Control.DeepSeq (deepseq)
import           Control.Exception.Lifted (bracket)
import           Control.Concurrent.MVar.Lifted (newMVar, takeMVar, putMVar)
import           Control.Monad ((>=>), void, when)
import qualified Data.ByteString as ByteString
import           "http2" Network.HTTP2.Client (HTTP2Error)
import           Network.HTTP2.Frame (FrameHeader(..), FrameFlags, FramePayload, encodeInfo, decodeFramePayload)
import qualified Network.HTTP2.Frame as HTTP2
import           Network.Socket (HostName, PortNumber)
import qualified Network.TLS as TLS

import           Network.HTTP2.Client.Exceptions
import           Network.HTTP2.Client.RawConnection

data Http2FrameConnection = Http2FrameConnection {
    _makeFrameClientStream :: HTTP2.StreamId -> Http2FrameClientStream
  -- ^ Starts a new client stream.
  , _serverStream     :: Http2ServerStream
  -- ^ Receives frames from a server.
  , _closeConnection  :: ClientIO ()
  -- ^ Function that will close the network connection.
  }

-- | Closes the Http2FrameConnection abruptly.
closeConnection :: Http2FrameConnection -> ClientIO ()
closeConnection = _closeConnection

-- | Creates a client stream.
makeFrameClientStream :: Http2FrameConnection
                      -> HTTP2.StreamId
                      -> Http2FrameClientStream
makeFrameClientStream = _makeFrameClientStream

data Http2FrameClientStream = Http2FrameClientStream {
    _sendFrames :: ClientIO [(FrameFlags -> FrameFlags, FramePayload)] -> ClientIO ()
  -- ^ Sends a frame to the server.
  -- The first argument is a FrameFlags modifier (e.g., to sed the
  -- end-of-stream flag).
  , _getStreamId :: HTTP2.StreamId -- TODO: hide me
  }

-- | Sends a frame to the server.
sendOne :: Http2FrameClientStream -> (FrameFlags -> FrameFlags) -> FramePayload -> ClientIO ()
sendOne client f payload = _sendFrames client (pure [(f, payload)])

-- | Sends multiple back-to-back frames to the server.
sendBackToBack :: Http2FrameClientStream -> [(FrameFlags -> FrameFlags, FramePayload)] -> ClientIO ()
sendBackToBack client payloads = _sendFrames client (pure payloads)

data Http2ServerStream = Http2ServerStream {
    _nextHeaderAndFrame :: ClientIO (FrameHeader, Either HTTP2Error FramePayload)
  }

-- | Waits for the next frame from the server.
next :: Http2FrameConnection -> ClientIO (FrameHeader, Either HTTP2Error FramePayload)
next = _nextHeaderAndFrame . _serverStream

-- | Adds framing around a 'RawHttp2Connection'.
frameHttp2RawConnection
  :: RawHttp2Connection
  -> ClientIO Http2FrameConnection
frameHttp2RawConnection http2conn = do
    -- Prepare a local mutex, this mutex should never escape the
    -- function's scope. Else it might lead to bugs (e.g.,
    -- https://ro-che.info/articles/2014-07-30-bracket )
    writerMutex <- newMVar ()

    let writeProtect io =
            bracket (takeMVar writerMutex) (putMVar writerMutex) (const io)

    -- Define handlers.
    let makeClientStream streamID =
            let putFrame modifyFF frame =
                    let info = encodeInfo modifyFF streamID
                    in HTTP2.encodeFrame info frame
                putFrames f = writeProtect . void $ do
                    xs <- f
                    let ys = fmap (uncurry putFrame) xs
                    -- Force evaluation of frames serialization whilst
                    -- write-protected to avoid out-of-order errrors.
                    deepseq ys (_sendRaw http2conn ys)
             in Http2FrameClientStream putFrames streamID

        nextServerFrameChunk = Http2ServerStream $ do
            b9 <- _nextRaw http2conn 9
            when (ByteString.length b9 /= 9) $ throwError $ EarlyEndOfStream
            let (fTy, fh@FrameHeader{..}) = HTTP2.decodeFrameHeader b9
            let decoder = decodeFramePayload fTy
            buf <- _nextRaw http2conn payloadLength
            when (ByteString.length buf /= payloadLength) $ throwError $ EarlyEndOfStream
            -- TODO: consider splitting the iteration here to give a chance to
            -- _not_ decode the frame, or consider lazyness enough.
            let nf = decoder fh buf
            pure (fh, nf)

        gtfo = _close http2conn

    return $ Http2FrameConnection makeClientStream nextServerFrameChunk gtfo

-- | Creates a new 'Http2FrameConnection' to a given host for a frame-to-frame communication.
newHttp2FrameConnection :: HostName
                        -> PortNumber
                        -> Maybe TLS.ClientParams
                        -> ClientIO Http2FrameConnection
newHttp2FrameConnection host port params = do
    frameHttp2RawConnection =<< newRawHttp2Connection host port params
