import Network.HTTP2.Client
import Network.HTTP2.Client.FrameConnection

main :: IO ()
main = do
    -- only demonstrates test-client setup
    let serverstream = Http2ServerStream undefined
    let makeframestream sid = Http2FrameClientStream (print . fmap snd) sid
    let fakeFrameConn = Http2FrameConnection makeframestream serverstream undefined
    _ <- wrapFrameClient fakeFrameConn 2048 2048 []
    putStrLn "OK"
