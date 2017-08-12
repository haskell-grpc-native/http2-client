
module Network.HTTP2.Client.Helpers where

import           Data.Time.Clock (UTCTime, getCurrentTime)
import qualified Network.HTTP2 as HTTP2
import           Data.ByteString (ByteString)
import           Control.Concurrent (threadDelay)
import           Control.Concurrent.Async (race)

import Network.HTTP2.Client

type PingReply = (UTCTime, UTCTime, Either () (HTTP2.FrameHeader, HTTP2.FramePayload))

ping :: Int -> ByteString -> Http2Client -> IO PingReply
ping timeout msg conn = do
    t0 <- getCurrentTime
    waitPing <- _ping conn msg
    pingReply <- race (threadDelay timeout) waitPing
    t1 <- getCurrentTime
    return $ (t0, t1, pingReply)
