First you need some imports and pragmas to make our life easier while typing
string literals.

> {-# LANGUAGE OverloadedStrings #-}

Main http2-client imports.

> import Network.HTTP2.Client
> import Network.HTTP2.Client.Helpers

Other imports, that we may eventually hide.

> import Network.HTTP2
> import Data.Default.Class (def)
> import Network.TLS as TLS
> import Network.TLS.Extra.Cipher as TLS
> 
> main :: IO ()
> main = do

First, create a connection, you need to specify the host and port you want to
connect to. Unlike HTTP, HTTP2 proposes to use TLS, hence, the port should
almost always be 443 instead of 80.

>     frameConn <- newHttp2FrameConnection "www.google.com" 443 (Just tlsParams )

The 'runHttp2Client' function takes control of the current thread so that we
never leave an internal thread leaking, even in presence of asynchronous
exceptions (likely in networked systems). Hence, the body of the logic we want
to perform is passed as a callback to 'runHttp2Client'. This callback is the
last argument for synctactic reason.

We also need to give more arguments to 'runHttp2Client'. The 8k values
corresponds to header sizes for sending/receiving. If you expect to receive or
send queries with more than 8MB of sent/received buffers, then you should tune
these values. The settings at the list gives the server a warrant to send more
bytes as soon as the server is ready to send queries (cf. HTTP2 flow control).

>     runHttp2Client frameConn 8192 8192 [(SettingsInitialWindowSize,10000000)] defaultGoAwayHandler ignoreFallbackHandler $ \conn -> do

We need to update the flow-control window for a snappy experience, so add
credit to the whole connection (else the SettingsInitialWindowSize would be
useless). Then, we immediately transfer credit to the server using
_updateWindow. We don't expect to receive more data for this connection so
we're good to go, but in a long-running application we would have to query this
function a number of time.

>       let fc = _incomingFlowControl conn
>       _addCredit fc 10000000
>       _ <- _updateWindow fc

Prepare the HTTP request using, first meta-headers, then normal headers.

>       let requestHeaders = [ (":method", "GET")
>                            , (":scheme", "https")
>                            , (":path", "?q=http2")
>                            , (":authority", "www.google.com")
>                            ]

Start a new stream. A new stream opened by a client takes two steps: first we
initialize the stream then we wait for a reply (i.e., we handle the reply).  If
you were sending an HTTP POST you would be sending data from the client to the
server, which requires outbound flow-control too.

>       _ <- withHttp2Stream conn $ \stream ->
>           let

For a simple HTTP GET, the headers constitute the whole query. We don't plan to
send more HTTP headers in continuation frames, hence we tell the server that
the headers are sent (so that the server can start generating a response). We
also tell the server that we're not gonna send more data with the setEndStream
flag.

>             initStream = headers stream requestHeaders (setEndHeader . setEndStream)

The handler uses the high-level waitStream, which blocks and waits for the
whole query result. The fromStreamResult coalesces every single frames from the
response (each of which may fail) as a single tuple with headers and the body
reply, wrapped in a single error.

If you expected the server to send you some data you can use onPushPromise with
a handler with the same type and 'waitStream' mechanism as the
client-originated streams (however with its own flow-control context).

>             resetPushPromises _ pps _ _ _ = _rst pps RefusedStream
>
>             handler sfc _ = do
>                 waitStream conn stream sfc resetPushPromises >>= print . fromStreamResult

We've defined an initializer and a handler so far.

>           in 

We need to package the initializer and the handler in a StreamDefinition
object. Once you're done, the _startStream function will manage your stream
synchronously. If you wanted to run multiple concurrent queries then you should
have one async per stream, and pay attention to the return value of
_startStream.

>             StreamDefinition initStream handler

We are done, congratz!

>       putStrLn "done"
>       _goaway conn NoError "https://github.com/lucasdicioccio/http2-client example"

You need to pass some TLS parameters. Here are a settings that could work with
an SSL verification that accepts any server certificate.

> tlsParams :: ClientParams
> tlsParams = TLS.ClientParams {
>     TLS.clientWantSessionResume    = Nothing
>   , TLS.clientUseMaxFragmentLength = Nothing
>   , TLS.clientServerIdentification = ("127.0.0.1", "")
>   , TLS.clientUseServerNameIndication = True
>   , TLS.clientShared               = def
>   , TLS.clientHooks                = def { TLS.onServerCertificate = \_ _ _ _ -> return [] }
>   , TLS.clientSupported            = def { TLS.supportedCiphers = TLS.ciphersuite_default }
>   , TLS.clientDebug                = def
>   }


An example output is as below:

$ http2-client-example
Right ([(":status","302"),("location","https://www.google.fr/?q=http2&gws_rd=cr&ei=7mOXWY6IMsSya_f2gsAJ"),("cache-control","private"),("content-type","text/html; charset=UTF-8"),("p3p","CP=\"This is not a P3P policy! See https://www.google.com/support/accounts/answer/151657?hl=en for more info.\""),("date","Fri, 18 Aug 2017 22:02:22 GMT"),("server","gws"),("content-length","269"),("x-xss-protection","1; mode=block"),("x-frame-options","SAMEORIGIN"),("set-cookie","NID=110=KvJPXSY6bwoZ1nJZe7LkRLu8GfSQIis1BCmh0u6agjDqyu4Ny8iAbmtZJSUXRen47uBjVmumFF8itvEDqQkVWTK3rKS1SAviGtzcoFj4Qel7FH5FpB2hvijgN1JFEbNM; expires=Sat, 17-Feb-2018 22:02:22 GMT; path=/; domain=.google.com; HttpOnly"),("alt-svc","quic=\":443\"; ma=2592000; v=\"39,38,37,35\"")],"<HTML><HEAD><meta http-equiv=\"content-type\" content=\"text/html;charset=utf-8\">\n<TITLE>302 Moved</TITLE></HEAD><BODY>\n<H1>302 Moved</H1>\nThe document has moved\n<A HREF=\"https://www.google.fr/?q=http2&amp;gws_rd=cr&amp;ei=7mOXWY6IMsSya_f2gsAJ\">here</A>.\r\n</BODY></HTML>\r\n")
done
