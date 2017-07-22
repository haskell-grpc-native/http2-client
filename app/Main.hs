{-# LANGUAGE OverloadedStrings #-}
module Main where

import Network.HTTP2.Client

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

    conn <- newHttp2Client host port tlsParams
    -- _addCredit (_flowControl conn) largestWindowSize
    _ <- forkIO $ forever $ do
            threadDelay 1000000
            _updateWindow $ _flowControl conn

    _settings conn [ (HTTP2.SettingsMaxFrameSize, 32768)
                   , (HTTP2.SettingsEnablePush, 0)
                   ]
    _ping conn "pingpong"

    let go = forever $ do
            _startStream cli $ \stream ->
                let init = _headers stream headersPairs dontSplitHeaderBlockFragments HTTP2.setEndStream
                    handler creditStream = do
                        _waitHeaders stream >>= print
                        godata
                        print "stream ended"
                        threadDelay 1000000
                          where
                            godata = do
                                (fh, x) <- _waitData stream
                                print (fmap (\bs -> (ByteString.length bs, ByteString.take 20 bs)) x)
                                when (not $ HTTP2.testEndStream (HTTP2.flags fh)) $ do
                                    _updateWindow $ streamFlowControl
                                    godata
                in StreamActions init handler
    waitAnyCancel =<< traverse async [go]
    _gtfo conn HTTP2.NoError "thx <(=O.O=)>"
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
