
module Network.HTTP2.Client.Channels (
   FramesChan
 , HeadersChan
 , PushPromisesChan
 , waitHeaders
 , waitHeadersWithStreamId
 , waitFrame
 , waitFrameWithStreamId
 , waitPushPromiseWithParentStreamId
 , waitFrameWithTypeId
 , waitFrameWithTypeIdForStreamId
 , isPingReply
 , isSettingsReply
 , hasStreamId
 , hasTypeId
 , whenFrame
 , whenFrameElse
 , module Control.Concurrent.Chan
 ) where

import           Control.Concurrent.Chan (Chan, readChan, newChan, dupChan, writeChan)
import           Control.Exception (Exception, throwIO)
import           Data.ByteString (ByteString)
import           Network.HPACK as HPACK
import           Network.HTTP2 as HTTP2

type FramesChan e = Chan (FrameHeader, Either e FramePayload)

type HeadersChanContent = (FrameHeader, StreamId, Either ErrorCode HeaderList)

type HeadersChan = Chan HeadersChanContent

type PushPromisesChanContent e = (StreamId, FramesChan e, HeadersChan, StreamId, HeaderList)

type PushPromisesChan e = Chan (PushPromisesChanContent e)

waitFrameWithStreamId
  :: Exception e
  => StreamId
  -> FramesChan e
  -> IO (FrameHeader, FramePayload)
waitFrameWithStreamId sid = waitFrame (\h _ -> streamId h == sid)

waitFrameWithTypeId
  :: (Exception e)
  => [FrameTypeId]
  -> FramesChan e
  -> IO (FrameHeader, FramePayload)
waitFrameWithTypeId tids = waitFrame (\_ p -> HTTP2.framePayloadToFrameTypeId p `elem` tids)

waitFrameWithTypeIdForStreamId
  :: (Exception e)
  => StreamId
  -> [FrameTypeId]
  -> FramesChan e
  -> IO (FrameHeader, FramePayload)
waitFrameWithTypeIdForStreamId sid tids =
    waitFrame (\h p -> streamId h == sid && HTTP2.framePayloadToFrameTypeId p `elem` tids)

waitFrame
  :: Exception e
  => (FrameHeader -> FramePayload -> Bool)
  -> FramesChan e
  -> IO (FrameHeader, FramePayload)
waitFrame test chan =
    loop
  where
    loop = do
        (fHead, fPayload) <- readChan chan
        dat <- either throwIO pure fPayload
        if test fHead dat
        then return (fHead, dat)
        else loop

whenFrame
  :: Exception e
  => (FrameHeader -> FramePayload -> Bool)
  -> (FrameHeader, Either e FramePayload)
  -> ((FrameHeader, FramePayload) -> IO ())
  -> IO ()
whenFrame test (fHead, fPayload) handle = do
    dat <- either throwIO pure fPayload
    if test fHead dat
    then handle (fHead, dat)
    else pure ()

whenFrameElse
  :: Exception e
  => (FrameHeader -> FramePayload -> Bool)
  -> (FrameHeader, Either e FramePayload)
  -> ((FrameHeader, FramePayload) -> IO a)
  -> ((FrameHeader, FramePayload) -> IO a)
  -> IO a
whenFrameElse test (fHead, fPayload) handleTrue handleFalse = do
    dat <- either throwIO pure fPayload
    if test fHead dat
    then handleTrue (fHead, dat)
    else handleFalse (fHead, dat)

hasStreamId :: StreamId -> FrameHeader -> FramePayload -> Bool
hasStreamId sid h _ = streamId h == sid

hasTypeId :: [FrameTypeId] -> FrameHeader -> FramePayload -> Bool
hasTypeId tids _ p = HTTP2.framePayloadToFrameTypeId p `elem` tids

isPingReply :: ByteString -> FrameHeader -> FramePayload -> Bool
isPingReply datSent _ (PingFrame datRcv) = datSent == datRcv
isPingReply _       _ _                  = False

isSettingsReply :: FrameHeader -> FramePayload -> Bool
isSettingsReply fh (SettingsFrame _) = HTTP2.testAck (flags fh)
isSettingsReply _ _                  = False

waitHeadersWithStreamId
  :: StreamId
  -> HeadersChan
  -> IO HeadersChanContent
waitHeadersWithStreamId sid =
    waitHeaders (\_ s _ -> s == sid)

waitHeaders
  :: (FrameHeader -> StreamId -> Either ErrorCode HeaderList -> Bool)
  -> HeadersChan
  -> IO HeadersChanContent
waitHeaders test chan =
    loop
  where
    loop = do
        tuple@(fH, sId, hdrs) <- readChan chan
        if test fH sId hdrs
        then return tuple
        else loop

waitPushPromiseWithParentStreamId
  :: StreamId
  -> PushPromisesChan e
  -> IO (PushPromisesChanContent e)
waitPushPromiseWithParentStreamId sid chan =
    loop
  where
    loop = do
        tuple@(parentSid,_,_,_,_) <- readChan chan
        if parentSid == sid
        then return tuple
        else loop
