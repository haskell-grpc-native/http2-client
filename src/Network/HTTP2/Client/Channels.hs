
module Network.HTTP2.Client.Channels (
   FramesChan
 , hasStreamId
 , hasTypeId
 , whenFrame
 , whenFrameElse
 -- re-exports
 , module Control.Concurrent.Chan
 ) where

import           Control.Concurrent.Chan (Chan, readChan, newChan, writeChan)
import           Control.Exception (Exception, throwIO)
import           Network.HTTP2 (StreamId, FrameHeader, FramePayload, FrameTypeId, framePayloadToFrameTypeId, streamId)

type FramesChan e = Chan (FrameHeader, Either e FramePayload)

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
hasTypeId tids _ p = framePayloadToFrameTypeId p `elem` tids
