{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards  #-}
{-# LANGUAGE RankNTypes  #-}

module Network.HTTP2.Client.RawConnection (
      RawHttp2Connection (..)
    , newRawHttp2Connection
    ) where

import           Control.Monad (forever)
import           Control.Concurrent.Async (Async, async, link)
import           Control.Concurrent.STM (atomically, retry)
import           Control.Concurrent.STM.TVar (TVar, modifyTVar', newTVarIO, readTVar, writeTVar)
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
    (a,getRaw) <- startReadWorker (recv skt)
    link a
    let doClose = close skt
    return $ RawHttp2Connection putRaw getRaw doClose

tlsRaw :: Socket -> TLS.ClientParams -> IO RawHttp2Connection
tlsRaw skt params = do
    -- Connects to SSL
    tlsContext <- TLS.contextNew skt (modifyParams params)
    TLS.handshake tlsContext

    -- Define raw byte-stream handlers.
    let putRaw        = TLS.sendData tlsContext . fromChunks
    (a,getRaw) <- startReadWorker (const $ TLS.recvData tlsContext)
    link a
    let doClose       = TLS.bye tlsContext >> TLS.contextClose tlsContext

    return $ RawHttp2Connection putRaw getRaw doClose
  where
    modifyParams prms = prms {
        TLS.clientHooks = (TLS.clientHooks prms) {
            TLS.onSuggestALPN = return $ Just [ "h2", "h2-17" ]
          }
      }

startReadWorker
  :: (Int -> IO ByteString)
  -> IO (Async (), (Int -> IO ByteString))
startReadWorker get = do
    buf <- newTVarIO ""
    a <- async $ readWorkerLoop buf get
    return $ (a, getRawWorker buf)

readWorkerLoop :: TVar ByteString -> (Int -> IO ByteString) -> IO ()
readWorkerLoop buf next = forever $ do
    dat <- next 4096
    atomically $ modifyTVar' buf (\bs -> (bs <> dat))

getRawWorker :: TVar ByteString -> Int -> IO ByteString
getRawWorker buf amount = atomically $ do
    dat <- readTVar buf
    if amount > ByteString.length dat
    then retry
    else do
        writeTVar buf (ByteString.drop amount dat)
        return $ ByteString.take amount dat
