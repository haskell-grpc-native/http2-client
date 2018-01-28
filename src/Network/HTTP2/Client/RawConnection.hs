{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards  #-}
{-# LANGUAGE RankNTypes  #-}

module Network.HTTP2.Client.RawConnection (
      RawHttp2Connection (..)
    , newRawHttp2Connection
    ) where

import           Control.Monad (forever, when)
import           Control.Concurrent.Async (Async, async, cancel, pollSTM)
import           Control.Concurrent.STM (STM, atomically, retry, throwSTM)
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
    (b,putRaw) <- startWriteWorker (sendMany skt)
    (a,getRaw) <- startReadWorker (recv skt)
    let doClose = close skt >> cancel a >> cancel b
    return $ RawHttp2Connection (atomically . putRaw) (atomically . getRaw) doClose

tlsRaw :: Socket -> TLS.ClientParams -> IO RawHttp2Connection
tlsRaw skt params = do
    -- Connects to SSL
    tlsContext <- TLS.contextNew skt (modifyParams params)
    TLS.handshake tlsContext

    (b,putRaw) <- startWriteWorker (TLS.sendData tlsContext . fromChunks)
    (a,getRaw) <- startReadWorker (const $ TLS.recvData tlsContext)
    let doClose       = TLS.bye tlsContext >> TLS.contextClose tlsContext >> cancel a >> cancel b

    return $ RawHttp2Connection (atomically . putRaw) (atomically . getRaw) doClose
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
    b <- async $ forever $ do
            xs <- atomically $ do
                chunks <- readTVar outQ
                when (null chunks) retry
                writeTVar outQ []
                return chunks
            sendChunks xs
    return (b, putRaw)

startReadWorker
  :: (Int -> IO ByteString)
  -> IO (Async (), (Int -> STM ByteString))
startReadWorker get = do
    buf <- newTVarIO ""
    a <- async $ readWorkerLoop buf get
    return $ (a, getRawWorker a buf)

readWorkerLoop :: TVar ByteString -> (Int -> IO ByteString) -> IO ()
readWorkerLoop buf next = forever $ do
    dat <- next 4096
    atomically $ modifyTVar' buf (\bs -> (bs <> dat))

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
