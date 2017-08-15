
module Network.HTTP2.Client.Helpers where

import           Data.Time.Clock (UTCTime, getCurrentTime)
import qualified Network.HTTP2 as HTTP2
import qualified Network.HPACK as HPACK
import           Data.ByteString (ByteString)
import           Control.Concurrent (threadDelay)
import           Control.Concurrent.Async (race)
import           Control.Monad (forever)

import Network.HTTP2.Client

-- | Opaque type to express an action which timed out.
data TimedOut = TimedOut
  deriving Show

-- | Result for a 'ping'.
type PingReply = (UTCTime, UTCTime, Either TimedOut (HTTP2.FrameHeader, HTTP2.FramePayload))

-- | Performs a 'ping' and waits for a reply up to a given timeout (in
-- microseconds).
ping :: Http2Client
     -- ^ client connection
     -> Int
     -- ^ timeout in microseconds
     -> ByteString
     -- ^ 8-bytes message to uniquely identify the reply
     -> IO PingReply
ping conn timeout msg = do
    t0 <- getCurrentTime
    waitPing <- _ping conn msg
    pingReply <- race (threadDelay timeout >> return TimedOut) waitPing
    t1 <- getCurrentTime
    return $ (t0, t1, pingReply)

-- | Result containing the unpacked headers and all frames received in on a
-- stream. See 'StreamResponse' and 'fromStreamResult' to get a higher-level
-- utility.
type StreamResult = (Either HTTP2.ErrorCode HPACK.HeaderList, [Either HTTP2.ErrorCode ByteString])

-- | An HTTP2 response, once fully received, is made of headers and a payload.
type StreamResponse = (HPACK.HeaderList, ByteString)

-- | Wait for a stream until completion.
--
-- This function is fine if you don't want to consume results in chunks.
waitStream :: Http2Stream -> IncomingFlowControl -> IO StreamResult
waitStream stream streamFlowControl = do
    (_,_,hdrs) <- _waitHeaders stream
    dataFrames <- moredata []
    return (hdrs, reverse dataFrames)
  where
    moredata xs = do
        (fh, x) <- _waitData stream
        if HTTP2.testEndStream (HTTP2.flags fh)
        then
            return (x:xs)
        else do
            _ <- _updateWindow $ streamFlowControl
            moredata (x:xs)

-- | Converts a StreamResult to a StramResponse, stopping at the first error
-- using the `Either HTTP2.ErrorCode` monad.
fromStreamResult :: StreamResult -> Either HTTP2.ErrorCode StreamResponse
fromStreamResult (headersE, chunksE) = do
    headers <- headersE
    chunks <- sequence chunksE
    return (headers, mconcat chunks)

-- | Sequentially every push-promise with a handler.
--
-- This function runs forever and you should wrap it with 'withAsync'.
onPushPromise :: Http2Stream -> PushPromiseHandler -> IO ()
onPushPromise stream handler = forever $ do
    _waitPushPromise stream handler
