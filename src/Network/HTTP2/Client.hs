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
    -- * Interact at the raw connections.
    , RawHttp2Connection (..)
    , newRawHttp2Connection
    ) where

import           Control.Exception (bracket)
import           Control.Concurrent.MVar (newMVar, takeMVar, putMVar)
import           Data.ByteString (ByteString)
import           Data.IORef (newIORef, atomicModifyIORef')
import           Network.Connection (connectTo, initConnectionContext, ConnectionParams(..), TLSSettings(..), connectionPut, connectionGetExact, connectionClose)
import           Network.HTTP2 (FrameHeader(..), FrameFlags, FramePayload, HTTP2Error, encodeInfo, decodeFramePayload)
import qualified Network.HTTP2 as HTTP2
import           Network.HPACK (useHuffman, newDynamicTableForEncoding, encodeHeader, defaultEncodeStrategy)
import           Network.Socket (HostName, PortNumber)
import qualified Network.TLS as TLS

-- TODO: catch connection errrors
data RawHttp2Connection = RawHttp2Connection {
    _sendRaw :: ByteString -> IO ()
  -- ^ Function to send raw data to the server.
  , _nextRaw :: Int -> IO ByteString
  -- ^ Function to block reading a datachunk of a given size from the server.
  , _close   :: IO ()
  }

-- | Initiates a RawHttp2Connection with a server.
--
-- The current code does not handle closing the connexion, yikes.
newRawHttp2Connection :: HostName
                      -- ^ Server's hostname.
                      -> PortNumber
                      -- ^ Server's port to connect to.
                      -> TLS.ClientParams
                      -- ^ TLS parameters. The 'TLS.onSuggestALPN' hook is
                      -- overwritten to always return ["h2", "h2-17"].
                      -> IO RawHttp2Connection
newRawHttp2Connection host port params = do
    -- Connects to SSL.
    ctx <- initConnectionContext
    conn <- connectTo ctx connParams

    -- Define raw byte-stream handlers.
    let putRaw dat    = connectionPut conn dat
    let getRaw amount = connectionGetExact conn amount
    let doClose       = connectionClose conn

    -- Initializes the HTTP2 stream.
    putRaw HTTP2.connectionPreface

    return $ RawHttp2Connection putRaw getRaw doClose
  where
    overwrittenALPNHook = (TLS.clientHooks params) {
        TLS.onSuggestALPN = return $ Just [ "h2", "h2-17" ]
      }
    modifiedParams = params { TLS.clientHooks = overwrittenALPNHook }
    connParams = ConnectionParams host port (Just . TLSSettings $ params) Nothing

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
