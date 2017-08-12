{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
module Main where

import           Control.Monad (forever, when, void)
import           Control.Concurrent (forkIO, threadDelay)
import           Control.Concurrent.Async (async, waitAnyCancel, race)
import qualified Data.ByteString.Char8 as ByteString
import           Data.Default.Class (def)
import           Data.Time.Clock (getCurrentTime, diffUTCTime)
import qualified Network.HTTP2 as HTTP2
import qualified Network.TLS as TLS
import qualified Network.TLS.Extra.Cipher as TLS
import           Options.Applicative
import           Data.Monoid ((<>))

import Network.HTTP2.Client

data QueryArgs = QueryArgs {
    _host :: !HostName
  , _port :: !PortNumber
  , _path :: !String
  }

clientArgs :: Parser QueryArgs
clientArgs =
    QueryArgs
        <$> host
        <*> port
        <*> path
  where
    host = strOption (long "host" <> value "127.0.0.1")
    path = strOption (long "path" <> value "/")
    port = option auto (long "port" <> value 443)

main :: IO ()
main = execParser opts >>= go
  where
    opts = info (helper <*> clientArgs) (mconcat [
        fullDesc
      , header "http2-client-exe: a CLI HTTP2 client written in Haskell"
      ])
    go QueryArgs{..} = client _host _port _path

client :: HostName -> PortNumber -> String -> IO ()
client host port path = do
    let headersPairs    = [ (":method", "GET")
                          , (":scheme", "https")
                          , (":path", ByteString.pack path)
                          , (":authority", ByteString.pack host)
                          , ("X-Stupid-Header1", ByteString.replicate 1024 '1')
                          ]

    let onPushPromise _ stream streamFlowControl _ = void $ forkIO $ do
            _waitHeaders stream >>= print
            moredata
            putStrLn "push stream ended"
            threadDelay 1000000
            where
                moredata = do
                    (fh, x) <- _waitData stream
                    print ("(push)" :: String, fmap (\bs -> (ByteString.length bs, ByteString.take 64 bs)) x)
                    when (not $ HTTP2.testEndStream (HTTP2.flags fh)) $ do
                        _updateWindow $ streamFlowControl
                        moredata

    conn <- newHttp2Client host port tlsParams onPushPromise

    _ <- forkIO $ forever $ do
            threadDelay 1000000
            _updateWindow $ _incomingFlowControl conn

    _settings conn [ (HTTP2.SettingsMaxFrameSize, 1048576)
                   , (HTTP2.SettingsMaxConcurrentStreams, 250)
                   , (HTTP2.SettingsMaxHeaderBlockSize, 1048576)
                   , (HTTP2.SettingsInitialWindowSize, 10485760)
                   ]
    threadDelay 2000000
    t0 <- getCurrentTime
    waitPing <- _ping conn "pingpong"
    pingReply <- race (threadDelay 5000000) waitPing 
    t1 <- getCurrentTime
    print $ ("ping-reply:" :: String, pingReply, diffUTCTime t1 t0)

    let go = -- forever $ do
            (_startStream conn $ \stream ->
                let initStream = _headers stream headersPairs id
                    handler incomingStreamFlowControl _ = do
                        sendData conn stream HTTP2.setEndStream (ByteString.replicate 1024 'p')
                        _waitHeaders stream >>= print
                        godata
                        -- print "stream ended"
                          where
                            godata = do
                                (fh, x) <- _waitData stream
                                print ("data" :: String, fmap (\bs -> (ByteString.length bs, ByteString.take 64 bs)) x)
                                when (not $ HTTP2.testEndStream (HTTP2.flags fh)) $ do
                                    _updateWindow $ incomingStreamFlowControl
                                    godata
                in StreamDefinition initStream handler)
    _ <- waitAnyCancel =<< traverse async (replicate 1 go)
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
