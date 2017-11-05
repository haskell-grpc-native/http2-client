{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards  #-}
{-# LANGUAGE RankNTypes  #-}

module Network.HTTP2.Client.RawConnection (
      RawHttp2Connection (..)
    , newRawHttp2Connection
    ) where

import           Data.ByteString (ByteString)
import           Network.Connection (connectTo, initConnectionContext, ConnectionParams(..), TLSSettings(..), connectionPut, connectionGetExact, connectionClose)
import qualified Network.HTTP2 as HTTP2
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
                      -> Maybe TLS.ClientParams
                      -- ^ TLS parameters. The 'TLS.onSuggestALPN' hook is
                      -- overwritten to always return ["h2", "h2-17"].
                      -> IO RawHttp2Connection
newRawHttp2Connection host port mparams = do
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
    overwriteALPNHook params = (TLS.clientHooks params) {
        TLS.onSuggestALPN = return $ Just [ "h2", "h2-17" ]
      }
    modifyParams params = params { TLS.clientHooks = overwriteALPNHook params }
    connParams = ConnectionParams host port (TLSSettings . modifyParams <$> mparams) Nothing
