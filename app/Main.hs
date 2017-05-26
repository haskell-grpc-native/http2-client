{-# LANGUAGE OverloadedStrings #-}
module Main where

import Network.HTTP2.Client (newHttp2FrameConnection, send, next)
import Network.HTTP2.Client (newHttp2Client, newHpackEncoder, startStream, Http2ClientStream(..), creditWindow)

import           Control.Monad (forever, when)
import           Control.Concurrent (forkIO, threadDelay)
import           Control.Concurrent.Async (async, waitAnyCancel)
import           Data.IORef (atomicModifyIORef', atomicModifyIORef, newIORef)
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

    let go = forever $ do
            startStream cli encoder $ \stream ->
                let first = _headersFrame stream headersPairs
                    second = do
                        pair@(fH,payload) <- _waitFrame stream
                        print pair
                        case payload of
                            (Right (HTTP2.DataFrame _)) ->
                                creditWindow cli (HTTP2.payloadLength fH)
                            otherwise                   ->
                                return ()
                        if HTTP2.testEndStream (HTTP2.flags fH)
                        then return()
                        else second
                in (first, second)
    waitAnyCancel =<< traverse async [go, go, go]
    return ()
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
