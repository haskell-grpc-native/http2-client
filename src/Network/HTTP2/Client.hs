{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards  #-}
{-# LANGUAGE RankNTypes  #-}

-- TODO: improve on received frame resources
-- * bounded channels
-- * do not broadcast to every chan but filter upfront with a lookup
module Network.HTTP2.Client (
      Http2Client
    , newHttp2Client
    , newHpackEncoder
    , withStream
    , Http2ClientStream(..)
    , module Network.HTTP2.Client.FrameConnection
    ) where

import           Data.ByteString (ByteString)
import           Data.IORef (newIORef, atomicModifyIORef)
import           Control.Concurrent (forkIO)
import           Control.Concurrent.Chan (newChan, dupChan, readChan, writeChan)
import           Control.Monad (forever)
import           Network.HPACK as HTTP2
import           Network.HTTP2 as HTTP2

import           Network.HTTP2.Client.FrameConnection

newtype HpackEncoder =
    HpackEncoder { encodeHeaders :: HeaderList -> IO HTTP2.HeaderBlockFragment }

data Http2Client = Http2Client {
    _newHpackEncoder  :: IO HpackEncoder
  , _withStream       :: forall a. HpackEncoder -> (Http2ClientStream -> IO a) -> IO a
  }

newHpackEncoder = _newHpackEncoder
withStream = _withStream

data Http2ClientStream = Http2ClientStream {
    _headersFrame :: HTTP2.HeaderList -> IO ()
  , _waitFrame    :: IO (HTTP2.FrameHeader, Either HTTP2.HTTP2Error HTTP2.FramePayload)
  }

newHttp2Client host port tlsParams = do
    conn <- newHttp2FrameConnection "127.0.0.1" 3000 tlsParams
    serverFrames <- newChan
    _ <- forkIO $ forever (next conn >>= writeChan serverFrames)

    let newEncoder = do
            let strategy = (HTTP2.defaultEncodeStrategy { HTTP2.useHuffman = True })
                bufsize  = 4096
            dt <- HTTP2.newDynamicTableForEncoding HTTP2.defaultDynamicTableSize
            return $ HpackEncoder $ HTTP2.encodeHeader strategy bufsize dt

    let withStream encoder doWork = do
            -- TODO: ensure strictly increasing frame number vs last opened frame
            openFrameClientStream conn $ \frameStream -> do
                serverStreamFrames <- dupChan serverFrames
                let _headersFrame headers = do
                        let eos = HTTP2.setEndStream . HTTP2.setEndHeader
                        payload <- HTTP2.HeadersFrame Nothing <$> (encodeHeaders encoder headers)
                        send frameStream eos payload
                -- TODO: filter on frame-ID
                let _waitFrame = readChan serverStreamFrames
                doWork $ Http2ClientStream{..}

    return $ Http2Client newEncoder withStream
