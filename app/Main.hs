{-# LANGUAGE OverloadedStrings #-}
module Main where

import Network.HTTP2.Client (newHttp2Connection, openClientStream, send, next)

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
    conn <- newHttp2Connection "127.0.0.1" 3000 tlsParams
    let headersPairs    = [ (":method", "GET")
                          , (":scheme", "https")
                          , (":path", "/hello")
                          , (":authority", "example.org")
                          , ("accept", "text/plain")
                          ]
    dt <- HTTP2.newDynamicTableForEncoding 1024
    query <- HTTP2.encodeHeader (HTTP2.defaultEncodeStrategy { HTTP2.useHuffman = True }) 1024 dt headersPairs

    -- TODO-bare:
    -- * create a context/async on a new client stream
    -- * close and reset streams
    -- * dispatch frames and headers until it's the last one
    -- TODO-control:
    -- * ack frames
    -- * ping/pong
    -- * handler flow control

    forkIO $ forever $ do
        openClientStream conn $ \stream -> do
            let eos = HTTP2.setEndStream . HTTP2.setEndHeader
            let payload = HTTP2.HeadersFrame Nothing query
            send stream eos payload

    forever $ do
        next conn >>= print

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
