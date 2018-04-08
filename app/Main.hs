{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
module Main where

import           Control.Concurrent (forkIO, myThreadId, throwTo, threadDelay)
import           Control.Concurrent.Async (async, waitAnyCancel)
import           Control.Monad (forever, when, void)
import           Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as ByteString
import           Data.Default.Class (def)
import           Data.Maybe (fromMaybe)
import           Data.Monoid ((<>))
import           Data.Time.Clock (diffUTCTime, getCurrentTime)
import qualified Network.HTTP2 as HTTP2
import qualified Network.TLS as TLS
import qualified Network.TLS.Extra.Cipher as TLS
import           Options.Applicative
import           System.IO

import Network.HTTP2.Client
import Network.HTTP2.Client.Helpers

type Path = ByteString
type Verb = ByteString

data PostData = PostBytestring !ByteString | PostFileContent FilePath
  deriving Show

postDataForString :: String -> PostData
postDataForString ('@':filepath) = PostFileContent filepath
postDataForString content        = PostBytestring (ByteString.pack content)

data ServerPushSwitch = PushEnabled | PushDisabled
  deriving Show

data Verbosity = Verbose | NonVerbose
  deriving Show

data UseTLS = UseTLS | PlainText
  deriving Show

data QueryArgs = QueryArgs {
    _host                       :: !HostName
  , _port                       :: !PortNumber
  , _verb                       :: !Verb
  , _path                       :: !Path
  , _extraHeaders               :: ![(ByteString, ByteString)]
  , _extraTrailers              :: ![(ByteString, ByteString)]
  , _postData                   :: !(Maybe PostData)
  , _interPingDelay             :: !Int
  , _pingTimeout                :: !Int
  , _interFlowControlUpdates    :: !Int
  , _settingsMaxConcurrency     :: !Int
  , _settingsAllowServerPush    :: !ServerPushSwitch
  , _settingsMaxFrameSize       :: !Int
  , _settingsMaxHeaderBlockSize :: !Int
  , _settingsInitialWindowSize  :: !Int
  , _initialWindowKick          :: !Int
  , _concurrentQueriesCount     :: !Int
  , _numberQueries              :: !Int
  , _finalDelay                 :: !Int
  , _finalMessage               :: !ByteString
  , _encoderBufsize             :: !Int
  , _decoderBufsize             :: !Int
  , _downloadPrefix             :: !FilePath
  , _verboseDebug               :: !Verbosity
  , _useTLS                     :: !UseTLS
  } deriving Show

clientArgs :: Parser QueryArgs
clientArgs =
    QueryArgs
        <$> host
        <*> port
        <*> verb
        <*> path
        <*> extraHeaders
        <*> extraTrailers
        <*> postData
        <*> milliseconds "inter-ping-delay-ms" 0
        <*> milliseconds "ping-timeout-ms" 5000
        <*> milliseconds "inter-flow-control-updates-ms" 1000
        <*> concurrency
        <*> allowPush
        <*> frameBytes
        <*> headersBytes
        <*> initialWindowBytes
        <*> initialWindowKick
        <*> numConcurrentThreads
        <*> numQueriesPerThread
        <*> milliseconds "delay-before-quitting-ms" 0
        <*> kthxByeMessage
        <*> encoderBufSize
        <*> decoderBufSize
        <*> downloadPrefix
        <*> verboseDebug
        <*> useTLS
  where
    bstrOption = fmap ByteString.pack . strOption
    milliseconds what base = fmap (*1000) $ option auto (long what <> value base)
    keyval kv = let (k,v1) = ByteString.break (== ':') kv in (k, ByteString.drop 1 v1)

    host = strOption (long "host" <> value "127.0.0.1")
    path = bstrOption (long "path" <> value "/")
    port = option auto (long "port" <> value 443)
    verb = bstrOption (long "verb" <> value "GET")
    extraHeaders = many (fmap keyval $ bstrOption (short 'H'))
    extraTrailers = many (fmap keyval $ bstrOption (short 'T'))
    postData = optional (fmap postDataForString (strOption (short 'd')))
    concurrency = option auto (long "max-concurrency" <> value 100)
    allowPush = flag PushEnabled PushDisabled (long "disable-server-push")
    frameBytes = option auto (long "max-frame-size" <> value 1048576)
    headersBytes = option auto (long "max-headers-list-size" <> value 1048576)
    initialWindowBytes = option auto (long "initial-window-size" <> value 10485760)
    initialWindowKick  = option auto (long "initial-window-kick" <> value 0)
    numConcurrentThreads = option auto (long "num-concurrent-threads" <> value 1)
    numQueriesPerThread = option auto (long "num-queries-per-thread" <> value 1)
    kthxByeMessage = bstrOption (long "exit-greeting" <> value "kthxbye (>;_;<)")
    encoderBufSize = option auto (long "hpack-encoder-buffer-size" <> value 4096)
    decoderBufSize = option auto (long "hpack-decoder-buffer-size" <> value 4096)
    downloadPrefix = strOption (long "push-files-prefix" <> value ":stdout-pp")
    verboseDebug = flag NonVerbose Verbose (long "verbose")
    useTLS = flag UseTLS PlainText (long "plain-text")

main :: IO ()
main = execParser opts >>= client
  where
    opts = info (helper <*> clientArgs) (mconcat [
        fullDesc
      , header "http2-client-exe: a CLI HTTP2 client written in Haskell"
      ])

client :: QueryArgs -> IO ()
client QueryArgs{..} = do
    hSetBuffering stdout LineBuffering

    -- If we need to post data then we prepare an upload function.
    -- Otherwise the function does nothing but we tell the server that we are
    -- finished with the stream after HTTP headers.
    --
    -- Note that this implementation reads the body from files and into memory
    -- (better for testing concurrency, worse for large uploads).
    (headersFlags, dataPostFunction) <- case (_extraTrailers, _postData) of
        ([], (Just (PostBytestring dataPayload))) ->
            return $ (id, upload dataPayload HTTP2.setEndStream)
        ([], (Just (PostFileContent filepath)))   -> do
            dataPayload <- ByteString.readFile filepath
            return $ (id, upload dataPayload HTTP2.setEndStream)
        ([], Nothing) ->
            return $ (HTTP2.setEndStream, \_ _ _ _ -> return ())
        (_, (Just (PostBytestring dataPayload))) ->
            return $ (id, (\c ofc s sofc -> do
                upload dataPayload id c ofc s sofc
                trailers s _extraTrailers HTTP2.setEndStream
                ))
        (_, (Just (PostFileContent filepath)))   -> do
            dataPayload <- ByteString.readFile filepath
            return $ (id, (\c ofc s sofc -> do
                upload dataPayload id c ofc s sofc
                trailers s _extraTrailers HTTP2.setEndStream
                ))
        (_, Nothing) ->
            return $ (id, (\_ _ s _ -> do
                trailers s _extraTrailers HTTP2.setEndStream
                ))

    let headersPairs    = [ (":method", _verb)
                          , (":scheme", "https")
                          , (":path", _path)
                          , (":authority", ByteString.pack _host)
                          ] <> _extraHeaders <> [("Trailer", ByteString.unwords $ fmap fst _extraTrailers)]


    let ppHandler n idx _ stream ppHdrs streamFlowControl _ = void $ forkIO $ do
            let pushpath = fromMaybe "unspecified-path" (lookup ":path" ppHdrs)
            timePrint ("push stream started" :: String, pushpath)
            ret <- fromStreamResult <$> waitStream stream streamFlowControl (ppHandler n idx)
            either (\e -> timePrint e) (dump PushPromiseFile pushpath n idx _downloadPrefix) ret
            timePrint ("push stream ended" :: String)

    let conf = [ (HTTP2.SettingsMaxFrameSize, _settingsMaxFrameSize)
               , (HTTP2.SettingsMaxConcurrentStreams, _settingsMaxConcurrency)
               , (HTTP2.SettingsMaxHeaderBlockSize, _settingsMaxHeaderBlockSize)
               , (HTTP2.SettingsInitialWindowSize, _settingsInitialWindowSize)
               , (HTTP2.SettingsEnablePush, case _settingsAllowServerPush of
                   PushEnabled -> 1 ; PushDisabled -> 0)
               ]
    timePrint conf

    let tlsSetting = case _useTLS of
            UseTLS ->
                Just tlsParams
            PlainText ->
                Nothing
    frameConn <- newHttp2FrameConnection _host _port tlsSetting
    let wrappedFrameConn = frameConn {
            _makeFrameClientStream = \sid ->
                let frameClient = (_makeFrameClientStream frameConn) sid
                in frameClient {
                       _sendFrames = \mkFrames -> do
                           xs <- mkFrames
                           print $ (">>> "::String, _getStreamId frameClient, map snd xs)
                           _sendFrames frameClient (pure xs)
                   }
          , _serverStream =
              let
                currentServerStrean = _serverStream frameConn
              in
                currentServerStrean {
                  _nextHeaderAndFrame = do
                      hdrFrame@(hdr,_) <- _nextHeaderAndFrame currentServerStrean
                      print ("<<< "::String, HTTP2.streamId hdr, hdrFrame)
                      return hdrFrame
                }
          }
    parentThread <- myThreadId
    let withConn = case _verboseDebug of
            Verbose ->
                runHttp2Client wrappedFrameConn _encoderBufsize _decoderBufsize conf defaultGoAwayHandler printUnhandledFrame
            NonVerbose ->
                runHttp2Client frameConn _encoderBufsize _decoderBufsize conf (throwTo parentThread) ignoreFallbackHandler

    withConn $ \conn -> do
      _addCredit (_incomingFlowControl conn) _initialWindowKick
      _ <- forkIO $ forever $ do
              updated <- _updateWindow $ _incomingFlowControl conn
              when updated $ timePrint ("sending flow-control update" :: String)
              threadDelay _interFlowControlUpdates

      _ <- forkIO $ when (_interPingDelay > 0) $ forever $ do
          threadDelay _interPingDelay
          (t0, t1, pingReply) <- ping conn _pingTimeout "pingpong"
          timePrint $ ("ping-reply:" :: String, pingReply, diffUTCTime t1 t0)

      let go 0 idx = timePrint $ "done worker: " <> show idx
          go n idx = do
              _ <- (withHttp2Stream conn $ \stream ->
                      let initStream =
                              headers stream headersPairs headersFlags
                          handler streamINFlowControl streamOUTFlowControl = do
                              timePrint $ "stream started " <> show (idx, n)
                              _ <- async $ do
                                  dataPostFunction conn
                                                   (_outgoingFlowControl conn)
                                                   stream
                                                   streamOUTFlowControl
                              ret <-  fromStreamResult <$> waitStream stream streamINFlowControl (ppHandler n idx)
                              either (\e -> timePrint e) (dump MainFile _path n idx _downloadPrefix) ret
                              timePrint $ "stream ended " <> show (idx, n)
                      in StreamDefinition initStream handler)
              go (n - 1) idx

      _ <- waitAnyCancel =<< traverse (async . go _numberQueries) [1 .. _concurrentQueriesCount]

      when (_finalDelay > 0) (threadDelay _finalDelay)


      _gtfo conn HTTP2.NoError _finalMessage
  where
    tlsParams = TLS.ClientParams {
          TLS.clientWantSessionResume    = Nothing
        , TLS.clientUseMaxFragmentLength = Nothing
        , TLS.clientServerIdentification = (_host, ByteString.pack $ show _port)
        , TLS.clientUseServerNameIndication = True
        , TLS.clientShared               = def
        , TLS.clientHooks                = def { TLS.onServerCertificate = \_ _ _ _ -> return []
                                               }
        , TLS.clientSupported            = def { TLS.supportedCiphers = TLS.ciphersuite_default }
        , TLS.clientDebug                = def
        }

data DumpType = MainFile | PushPromiseFile

dump :: DumpType -> Path -> Int -> Int -> FilePath -> StreamResponse -> IO ()
dump MainFile _ _ _ ":none" (hdrs, _, trls) = do
    timePrint hdrs
    timePrint trls
dump MainFile _ _ _ ":stdout" (hdrs, body, trls) = do
    timePrint hdrs
    ByteString.putStrLn body
    timePrint trls
dump PushPromiseFile _ _ _ ":stdout" (hdrs, _, trls) = do
    timePrint hdrs
    timePrint trls
dump MainFile _ _ _ ":stdout-pp" (hdrs, body, trls) = do
    timePrint hdrs
    ByteString.putStrLn body
    timePrint trls
dump PushPromiseFile _ _ _ ":stdout-pp" (hdrs, body, trls) = do
    timePrint hdrs
    ByteString.putStrLn body
    timePrint trls
dump _ querystring nquery nthread prefix (hdrs, body, trls) = do
    timePrint hdrs
    ByteString.writeFile filepath body
    timePrint trls
  where
    filepath = mconcat [ prefix
                       , "/" 
                       , show nquery
                       , "."
                       , show nthread
                       , ByteString.unpack $ cleanPath querystring
                       ]
    cleanPath = ByteString.takeWhile (/= '?')
              . ByteString.map (\c -> if c == '/' then '_' else c)

timePrint :: Show a => a -> IO ()
timePrint x = do
    tst <- getCurrentTime
    ByteString.hPutStrLn stderr $ ByteString.pack $ show (tst, x)

printUnhandledFrame :: FallBackFrameHandler
printUnhandledFrame (fh,fp) = timePrint ("UNHANDLED:"::String, fh, fp)
