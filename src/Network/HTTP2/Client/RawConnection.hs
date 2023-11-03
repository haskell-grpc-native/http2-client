{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards  #-}
{-# LANGUAGE RankNTypes  #-}

module Network.HTTP2.Client.RawConnection (
      RawHttp2Connection (..)
    , newRawHttp2Connection
    , newRawHttp2ConnectionUnix
    , newRawHttp2ConnectionSocket
    ) where

import           Control.Monad (forever, when)
import           Control.Concurrent.Async.Lifted (Async, async, cancel, pollSTM)
import           Control.Concurrent.STM (STM, atomically, check, orElse, retry, throwSTM)
import           Control.Concurrent.STM.TVar (TVar, modifyTVar', newTVarIO, readTVar, writeTVar)
import           Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import           Data.ByteString.Lazy (fromChunks)
import           Data.Monoid ((<>))
import qualified Network.HTTP2.Frame as HTTP2
import           Network.Socket hiding (recv)
import           Network.Socket.ByteString
import qualified Network.TLS as TLS

import           Network.HTTP2.Client.Exceptions

-- TODO: catch connection errrors
data RawHttp2Connection = RawHttp2Connection {
    _sendRaw :: [ByteString] -> ClientIO ()
  -- ^ Function to send raw data to the server.
  , _nextRaw :: Int -> ClientIO ByteString
  -- ^ Function to block reading a datachunk of a given size from the server.
  -- An empty chunk when asking for a length larger than 0 means the underlying
  -- network session is closed. A compliant HTP2 server should have sent a
  -- GOAWAY before such an event occurs.
  , _close   :: ClientIO ()
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
                      -> ClientIO RawHttp2Connection
newRawHttp2Connection host port mparams = do
    -- Connects to TCP.
    let hints = defaultHints { addrFlags = [AI_NUMERICSERV], addrSocketType = Stream }
    rSkt <- lift $ do
        addr:_ <- getAddrInfo (Just hints) (Just host) (Just $ show port)
        skt <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
        setSocketOption skt NoDelay 1
        connect skt (addrAddress addr)
        pure skt
    newRawHttp2ConnectionSocket rSkt mparams

-- | Initiates a RawHttp2Connection with a unix domain socket.
--
-- The current code does not handle closing the connexion, yikes.
newRawHttp2ConnectionUnix :: String
                          -- ^ Path to the socket.
                          -> Maybe TLS.ClientParams
                          -- ^ TLS parameters. The 'TLS.onSuggestALPN' hook is
                          -- overwritten to always return ["h2", "h2-17"].
                          -> ClientIO RawHttp2Connection
newRawHttp2ConnectionUnix path mparams = do
    rSkt <- lift $ do
        skt <- socket AF_UNIX Stream 0
        connect skt $ SockAddrUnix path
        pure skt
    newRawHttp2ConnectionSocket rSkt mparams

-- | Initiates a RawHttp2Connection with a server over a connected socket.
--
-- The current code does not handle closing the connexion, yikes.
-- Since 0.8.0.2
newRawHttp2ConnectionSocket
  :: Socket
  -- ^ A connected socket.
  -> Maybe TLS.ClientParams
  -- ^ TLS parameters. The 'TLS.onSuggestALPN' hook is
  -- overwritten to always return ["h2", "h2-17"].
  -> ClientIO RawHttp2Connection
newRawHttp2ConnectionSocket skt mparams = do
    -- Prepare structure with abstract API.
    conn <- lift $ maybe (plainTextRaw skt) (tlsRaw skt) mparams

    -- Initializes the HTTP2 stream.
    _sendRaw conn [HTTP2.connectionPreface]

    return conn

plainTextRaw :: Socket -> IO RawHttp2Connection
plainTextRaw skt = do
    (b,putRaw) <- startWriteWorker (sendMany skt)
    (a,getRaw) <- startReadWorker (recv skt)
    let doClose = lift $ cancel a >> cancel b >> close skt
    return $ RawHttp2Connection (lift . atomically . putRaw) (lift . atomically . getRaw) doClose

tlsRaw :: Socket -> TLS.ClientParams -> IO RawHttp2Connection
tlsRaw skt params = do
    -- Connects to SSL
    tlsContext <- TLS.contextNew skt (modifyParams params)
    TLS.handshake tlsContext

    (b,putRaw) <- startWriteWorker (TLS.sendData tlsContext . fromChunks)
    (a,getRaw) <- startReadWorker (const $ TLS.recvData tlsContext)
    let doClose       = lift $ cancel a >> cancel b >> TLS.bye tlsContext >> TLS.contextClose tlsContext

    return $ RawHttp2Connection (lift . atomically . putRaw) (lift . atomically . getRaw) doClose
  where
    modifyParams prms = prms {
        TLS.clientHooks = (TLS.clientHooks prms) {
            TLS.onSuggestALPN = return $ Just [ "h2", "h2-17" ]
          }
      }

startWriteWorker
  :: ([ByteString] -> IO ())
  -> IO (Async (), [ByteString] -> STM ())
startWriteWorker sendChunks = do
    outQ <- newTVarIO []
    let putRaw chunks = modifyTVar' outQ (\xs -> xs ++ chunks)
    b <- async $ writeWorkerLoop outQ sendChunks
    return (b, putRaw)

writeWorkerLoop :: TVar [ByteString] -> ([ByteString] -> IO ()) -> IO ()
writeWorkerLoop outQ sendChunks = forever $ do
    xs <- atomically $ do
        chunks <- readTVar outQ
        when (null chunks) retry
        writeTVar outQ []
        return chunks
    sendChunks xs

startReadWorker
  :: (Int -> IO ByteString)
  -> IO (Async (), (Int -> STM ByteString))
startReadWorker get = do
    remoteClosed <- newTVarIO False
    let onEof = atomically $ writeTVar remoteClosed True
    let emptyByteStringOnEof = readTVar remoteClosed >>= check >> pure ""

    buf <- newTVarIO ""
    a <- async $ readWorkerLoop buf get onEof

    return $ (a, \len -> getRawWorker a buf len `orElse` emptyByteStringOnEof)

readWorkerLoop :: TVar ByteString -> (Int -> IO ByteString) -> IO () -> IO ()
readWorkerLoop buf next onEof = go
  where
    go = do
        dat <- next 4096
        if ByteString.null dat
        then onEof
        else atomically (modifyTVar' buf (\bs -> (bs <> dat))) >> go

getRawWorker :: Async () -> TVar ByteString -> Int -> STM ByteString
getRawWorker a buf amount = do
    -- Verifies if the STM is alive, if dead, we re-throw the original
    -- exception.
    asyncStatus <- pollSTM a
    case asyncStatus of
        (Just (Left e)) -> throwSTM e
        _               -> return ()
    -- Read data consume, if there's enough, retry otherwise.
    dat <- readTVar buf
    if amount > ByteString.length dat
    then retry
    else do
        writeTVar buf (ByteString.drop amount dat)
        return $ ByteString.take amount dat
