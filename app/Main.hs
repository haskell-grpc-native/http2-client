{-# LANGUAGE OverloadedStrings #-}
module Main where

import Network.HTTP2.Client (newHttp2FrameConnection, send, next)
import Network.HTTP2.Client (newHttp2Client, Http2Client(..), Http2ClientStream(..), StreamActions(..), FlowControl(..))

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
    let largestWindowSize = HTTP2.maxWindowSize - HTTP2.defaultInitialWindowSize
    let headersPairs    = [ (":method", "GET")
                          , (":scheme", "https")
                          , (":path", "/hello")
                          , (":authority", "example.org")
                          , ("accept", "text/plain")
                          ]

    cli <- newHttp2Client "127.0.0.1" 3000 tlsParams
    _creditFlow (_flowControl cli) largestWindowSize
    encoder <- _newHpackEncoder cli
    _ <- forkIO $ do
            _updateWindow $ _flowControl cli
            threadDelay 1000000

    _settings cli []
    _ping cli "pingpong"
    _ping cli "pingpong"
    threadDelay 3000000

    let go = forever $ do
            _startStream cli encoder $ \stream ->
                let init = _headers stream headersPairs (HTTP2.setEndHeader . HTTP2.setEndStream)
                    handler creditStream = do
                        pair@(fH,payload) <- _waitFrame stream
                        print fH
                        case payload of
                            (Right (HTTP2.DataFrame _)) -> do
                                _creditFlow (_flowControl cli) (HTTP2.payloadLength fH)
                            otherwise                   ->
                                return ()
                        if HTTP2.testEndStream (HTTP2.flags fH)
                        then return ()
                        else handler creditStream
                in StreamActions init handler
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
