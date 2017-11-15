{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards  #-}
{-# LANGUAGE RankNTypes  #-}

module Network.HTTP2.Client.RawConnection (
      RawHttp2Connection (..)
    , newRawHttp2Connection
    ) where

import           Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as Char8
import qualified Data.ByteString.Base64 as Base64
import           Data.Monoid ((<>))
import           Network.Connection (Connection, connectionGetLine, connectTo, initConnectionContext, ConnectionParams(..), TLSSettings(..), connectionPut, connectionGetExact, connectionClose)
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
    conn <- newRawStream host port mparams
    -- Sends the HTTP2 preface.
    connectionPut conn HTTP2.connectionPreface
    return $ wrapConnection conn

newRawH2cConnection :: HostName
                    -- ^ Server's hostname.
                    -> PortNumber
                    -- ^ Server's port to connect to.
                    -> HTTP2.SettingsList
                    -- ^ Initial SETTINGS for the first query.
                    -> IO RawHttp2Connection
newRawH2cConnection host port settings = do
    -- TODO: allow hijacking HTTP query (including: path, verb, headers)
    conn <- newRawStream host port Nothing
    -- Initializes the HTTP1.1 upgrade.
    connectionPut conn $ upgradeFromHTTP1req host settings
    let loop = do
            x <- connectionGetLine 8096 conn
            if ByteString.null x then return () else loop
    -- Sends the HTTP2 preface.
    connectionPut conn HTTP2.connectionPreface
    return $ wrapConnection conn

upgradeFromHTTP1req :: HostName -> HTTP2.SettingsList -> ByteString
upgradeFromHTTP1req host setts = Char8.unlines [
    "GET / HTTP/1.1"
  , "Host: " <> Char8.pack host
  , "Connection: Upgrade, HTTP2-Settings"
  , "Upgrade: h2c"
  , "HTTP2-Settings: " <> Base64.encode encodedSettings
  , ""
  ]
  where
    encodedSettings = HTTP2.encodeFrame (HTTP2.encodeInfo id 1) (HTTP2.SettingsFrame setts)

wrapConnection :: Connection -> RawHttp2Connection
wrapConnection conn =
    let putRaw dat    = connectionPut conn dat
        getRaw amount = connectionGetExact conn amount
        doClose       = connectionClose conn

    in RawHttp2Connection putRaw getRaw doClose

-- | Initiates a RawHttp2Connection with a server.
--
-- The current code does not handle closing the connexion, yikes.
newRawStream :: HostName
            -- ^ Server's hostname.
            -> PortNumber
            -- ^ Server's port to connect to.
            -> Maybe TLS.ClientParams
            -- ^ TLS parameters. The 'TLS.onSuggestALPN' hook is
            -- overwritten to always return ["h2", "h2-17"].
            -> IO Connection
newRawStream host port mparams = do
    -- Connects to SSL or TCP. Over TLS we'll need to negotiate "h2" in ALPN.
    ctx <- initConnectionContext
    connectTo ctx connParams
  where
    overwriteALPNHook params = (TLS.clientHooks params) {
        TLS.onSuggestALPN = return $ Just [ "h2", "h2-17" ]
      }
    modifyParams params = params { TLS.clientHooks = overwriteALPNHook params }
    connParams = ConnectionParams host port (TLSSettings . modifyParams <$> mparams) Nothing
