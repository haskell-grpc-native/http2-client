{-# LANGUAGE OverloadedStrings #-}
module Main where

import Network.HTTP2.Client

import           Control.Monad (forever, when, void)
import           Control.Concurrent (forkIO, threadDelay)
import           Control.Concurrent.Async (async, waitAnyCancel)
import           Data.IORef (atomicModifyIORef', atomicModifyIORef, newIORef)
import qualified Data.ByteString.Char8 as ByteString
import           Data.Default.Class (def)
import qualified Network.HTTP2 as HTTP2
import qualified Network.HPACK as HTTP2
import qualified Network.TLS as TLS
import qualified Network.TLS.Extra.Cipher as TLS
import           System.Environment (getArgs)

main :: IO ()
main = getArgs >>= mainArgs

mainArgs :: [String] -> IO ()
mainArgs []                  = client "127.0.0.1" 3000 "/"
mainArgs (host:[])           = client host 443 "/"
mainArgs (host:port:[])      = client host (read port) "/"
mainArgs (host:port:path:[]) = client host (read port) path

client host port path = do
    let largestWindowSize = HTTP2.maxWindowSize - HTTP2.defaultInitialWindowSize
    let headersPairs    = [ (":method", "GET")
                          , (":scheme", "https")
                          , (":path", ByteString.pack path)
                          , (":authority", ByteString.pack host)
                          ]

    let onPushPromise stream streamFlowControl = void $ forkIO $ do
            _waitHeaders stream >>= print
            moredata
            print "push stream ended"
            threadDelay 1000000
            where
                moredata = do
                    (fh, x) <- _waitData stream
                    print ("(push)", fmap (\bs -> (ByteString.length bs, ByteString.take 64 bs)) x)
                    when (not $ HTTP2.testEndStream (HTTP2.flags fh)) $ do
                        _updateWindow $ streamFlowControl
                        moredata

    conn <- newHttp2Client host port tlsParams onPushPromise
    _addCredit (_flowControl conn) largestWindowSize
    _ <- forkIO $ forever $ do
            threadDelay 1000000
            _updateWindow $ _flowControl conn

    _settings conn [ (HTTP2.SettingsMaxFrameSize, 1048576)
                   , (HTTP2.SettingsMaxConcurrentStreams, 250)
                   , (HTTP2.SettingsMaxHeaderBlockSize, 1048576)
                   , (HTTP2.SettingsInitialWindowSize, 1048576)
                   ]
    threadDelay 200000
    _ping conn "pingpong"

    let go = -- forever $ do
            _startStream conn $ \stream ->
                let init = _headers stream headersPairs dontSplitHeaderBlockFragments id
                    handler streamFlowControl = do
                        _sendData stream HTTP2.setEndStream ""
                        _waitHeaders stream >>= print
                        godata
                        print "stream ended"
                          where
                            godata = do
                                (fh, x) <- _waitData stream
                                print ("data", fmap (\bs -> (ByteString.length bs, ByteString.take 64 bs)) x)
                                when (not $ HTTP2.testEndStream (HTTP2.flags fh)) $ do
                                    _updateWindow $ streamFlowControl
                                    godata
                in StreamActions init handler
    waitAnyCancel =<< traverse async [go]
    threadDelay 5000000
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
