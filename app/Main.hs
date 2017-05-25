{-# LANGUAGE OverloadedStrings #-}
module Main where

import Network.HTTP2.Client (newHttp2FrameConnection, send, next)
import Network.HTTP2.Client (newHttp2Client, newHpackEncoder, withStream, Http2ClientStream(..))

import           Control.Monad (forever)
import           Control.Concurrent (forkIO)
import           Data.Default.Class (def)
import qualified Network.HTTP2 as HTTP2
import qualified Network.HPACK as HTTP2
import qualified Network.TLS as TLS
import qualified Network.TLS.Extra.Cipher as TLS


main :: IO ()
main = client

client :: IO ()
client = do
    let headersPairs    = [ (":method", "GET")
                          , (":scheme", "https")
                          , (":path", "/hello")
                          , (":authority", "example.org")
                          , ("accept", "text/plain")
                          ]

    cli <- newHttp2Client "127.0.0.1" 3000 tlsParams
    encoder <- newHpackEncoder cli

    forever $ do
        withStream cli encoder $ \stream -> do
            _headersFrame stream headersPairs
            _waitFrame stream >>= print
  where
    tlsParams = TLS.ClientParams {
          TLS.clientWantSessionResume    = Nothing
        , TLS.clientUseMaxFragmentLength = Nothing
        , TLS.clientServerIdentification = ("127.0.0.1", "")
        , TLS.clientUseServerNameIndication = True
        , TLS.clientShared               = def
        , TLS.clientHooks                = def { TLS.onServerCertificate = \_ _ _ _ -> return []
                                               }
        , TLS.clientSupported            = def { TLS.supportedCiphers = TLS.ciphersuite_default }
        , TLS.clientDebug                = def
        }
