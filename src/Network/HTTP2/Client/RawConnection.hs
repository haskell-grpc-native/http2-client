{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards  #-}
{-# LANGUAGE RankNTypes  #-}

module Network.HTTP2.Client.RawConnection (
      RawHttp2Connection (..)
    , newRawHttp2Connection
    ) where

import           Data.IORef (newIORef, readIORef, writeIORef)
import           Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import           Data.ByteString.Lazy (fromChunks)
import           Data.Monoid ((<>))
import qualified Network.HTTP2 as HTTP2
import           Network.Socket hiding (recv)
import           Network.Socket.ByteString
import qualified Network.TLS as TLS

-- TODO: catch connection errrors
data RawHttp2Connection = RawHttp2Connection {
    _sendRaw :: [ByteString] -> IO ()
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
                      -> Maybe TLS.ClientParams
                      -- ^ TLS parameters. The 'TLS.onSuggestALPN' hook is
                      -- overwritten to always return ["h2", "h2-17"].
                      -> IO RawHttp2Connection
newRawHttp2Connection host port mparams = do
    -- Connects to TCP.
    let hints = defaultHints { addrFlags = [AI_NUMERICSERV], addrSocketType = Stream }
    addr:_ <- getAddrInfo (Just hints) (Just host) (Just $ show port)
    skt <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
    connect skt (addrAddress addr)

    -- Prepare structure with abstract API.
    conn <- maybe (plainTextRaw skt) (tlsRaw skt) mparams

    -- Initializes the HTTP2 stream.
    _sendRaw conn [HTTP2.connectionPreface]

    return conn


plainTextRaw :: Socket -> IO RawHttp2Connection
plainTextRaw skt = do
    let putRaw = sendMany skt
    remainder <- newIORef ""
    let getRaw amount = do
            -- TODO: improve re-writing of remainders by storing chunks instead of concatening chunks
            buf <- readIORef remainder
            if amount > ByteString.length buf
            then do
               dat <- recv skt 4096
               writeIORef remainder $ buf <> dat
               getRaw amount
            else do
               writeIORef remainder $ ByteString.drop amount buf
               return $ ByteString.take amount buf
    let doClose = close skt
    return $ RawHttp2Connection putRaw getRaw doClose

tlsRaw :: Socket -> TLS.ClientParams -> IO RawHttp2Connection
tlsRaw skt params = do
    -- Connects to SSL
    tlsContext <- TLS.contextNew skt (modifyParams params)
    TLS.handshake tlsContext

    -- Define raw byte-stream handlers.
    let putRaw        = TLS.sendData tlsContext . fromChunks
    remainder <- newIORef ""
    let getRaw amount = do
            -- TODO: improve re-writing of remainders by storing chunks instead of concatening chunks
            buf <- readIORef remainder
            if amount > ByteString.length buf
            then do
               dat <- TLS.recvData tlsContext
               writeIORef remainder $ buf <> dat
               getRaw amount
            else do
               writeIORef remainder $ ByteString.drop amount buf
               return $ ByteString.take amount buf
    let doClose       = TLS.bye tlsContext >> TLS.contextClose tlsContext

    return $ RawHttp2Connection putRaw getRaw doClose
  where
    modifyParams prms = prms {
        TLS.clientHooks = (TLS.clientHooks prms) {
            TLS.onSuggestALPN = return $ Just [ "h2", "h2-17" ]
          }
      }
