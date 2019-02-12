
module Network.HTTP2.Client.Exceptions (
    ClientIO
  , ClientError(..)
  , module Control.Monad.Except
  ) where

import           Control.Exception (Exception)
import           Control.Monad.Except (ExceptT, runExceptT, throwError, lift)

type ClientIO = ExceptT ClientError IO

-- | A set of errors as observed from the client.
data ClientError = EarlyEndOfStream
  -- ^ We received a TCP end-of-stream and there will be no further read-IOs possible on the connection.
  deriving (Show,Ord,Eq)
instance Exception ClientError -- For people who want to rethrow using Control.Exception

