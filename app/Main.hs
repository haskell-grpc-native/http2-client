{-# LANGUAGE OverloadedStrings #-}
module Main where

import Network.HTTP2.Client (newHttp2FrameConnection, send, next)
import Network.HTTP2.Client (newHttp2Client, newHpackEncoder, startStream, Http2ClientStream(..), windowUpdate)

import           Control.Monad (forever, when)
import           Control.Concurrent (forkIO, threadDelay)
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

    windowUpdate cli (HTTP2.maxWindowSize - HTTP2.defaultInitialWindowSize)
    credit <- newIORef 0

    let addCredit n = atomicModifyIORef credit (\c -> (c + n,()))
    forkIO $ forever $ do
        amount <- atomicModifyIORef' credit (\c -> (0, c))
        print ("crediting", amount)
        when (amount > 0) (windowUpdate cli amount)
        threadDelay 500000

    let go = forever $ do
            startStream cli encoder $ \stream ->
                let first = _headersFrame stream headersPairs
                    second = do
                        pair@(fH,payload) <- _waitFrame stream
                        print pair
                        case payload of
                            (Right (HTTP2.DataFrame _)) ->
                                addCredit (HTTP2.payloadLength fH)
                            otherwise                   ->
                                return ()
                        if HTTP2.testEndStream (HTTP2.flags fH)
                        then return()
                        else second
                in (first, second)
    go
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
