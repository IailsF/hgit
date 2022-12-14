{-# LANGUAGE OverloadedStrings #-}

module Cmd
  ( CatFileOpt(..)
  , HashObjectOpt(..)
  , WriteTreeOpt(..)
  , ReadTreeOpt(..)
  , CommitOpt(..)
  , LogOpt(..)
  , CheckoutOpt(..)
  , TagOpt(..)
  , KlogOpt(..)
  , BranchOpt(..)
  , StatusOpt(..)
  , ResetOpt(..)
  , Base.ResetMode(..)
  , ShowOpt(..)
  , initRepo
  , catFile
  , hashObject
  , writeTree
  , readTree
  , commit
  , log
  , checkout
  , tag
  , klog
  , branch
  , status
  , reset
  , showCommit
  ) where

import qualified Data.ByteString.Char8 as Char8

import           System.Directory      (createDirectoryIfMissing,
                                        doesDirectoryExist)
import           System.Exit           (exitFailure)
import           System.IO             (hPutStrLn, stderr, stdout)

import qualified Base
import           Const
import qualified Data
import qualified Data.ByteString       as BS
import qualified Data.ByteString.UTF8  as Utf8
import Prelude hiding (log)
import Control.Monad.Trans.Maybe (MaybeT(runMaybeT))
import Base (resolveOid)

preCheck :: IO a -> IO a
preCheck action = do
    repoExists <- doesDirectoryExist repoDir
    if repoExists then do
        action
    else do
        hPutStrLn stderr "Repository not initialized!"
        exitFailure

initRepo :: IO ()
initRepo = Base.initRepo

data CatFileOpt = MkCatFileOpt String

catFile :: CatFileOpt -> IO ()
catFile (MkCatFileOpt hash) = preCheck $ do
    obj <- runMaybeT $ Data.getObject hash
    maybe mempty (\(Data.MkObj _ content) -> Char8.putStrLn content) obj

newtype HashObjectOpt = MkHashObjectOpt String

hashObject :: HashObjectOpt -> IO ()
hashObject (MkHashObjectOpt file) = preCheck $ do
    content <- BS.readFile file
    hash <- Data.hashObject (Data.MkObj Data.Blob content)
    Char8.putStrLn ("saved: " <> hash)

data WriteTreeOpt = MkWriteTreeOpt FilePath

writeTree :: WriteTreeOpt -> IO ()
writeTree (MkWriteTreeOpt file) = preCheck $ do
    hash <- Base.writeTree file
    putStrLn (Utf8.toString hash)

data ReadTreeOpt = MkReadTreeOpt String

readTree :: ReadTreeOpt -> IO ()
readTree (MkReadTreeOpt oid) = preCheck $ do
    Base.readObj oid

data CommitOpt = MkCommitOpt String

commit :: CommitOpt -> IO ()
commit (MkCommitOpt msg) = preCheck $ do
    Base.commit msg

data LogOpt
    = MkEmptyLogOpt
    | MkLogOpt String

log :: LogOpt -> IO ()
log MkEmptyLogOpt = preCheck $ do
    Base.log "HEAD"
log (MkLogOpt oid) = preCheck $ do
    Base.log oid

data CheckoutOpt = MkCheckoutOpt String

checkout :: CheckoutOpt -> IO ()
checkout (MkCheckoutOpt oid) = preCheck $ do
    Base.checkout oid

data TagOpt = MkTagOpt [String]

tag :: TagOpt -> IO ()
tag (MkTagOpt []) = preCheck $ do
    hPutStrLn stderr "Tag name cannot be empty!"

tag (MkTagOpt [tagName]) = preCheck $ do
    Base.tag tagName "HEAD"

tag (MkTagOpt (tagName:oid:xs)) = preCheck $ do
    Base.tag tagName oid

data KlogOpt = MkKlogOpt

klog :: KlogOpt -> IO ()
klog MkKlogOpt = preCheck $ do
    Base.klog

data BranchOpt = MkBranchOpt [String]

branch :: BranchOpt -> IO ()
branch (MkBranchOpt []) = preCheck $ do
    Base.listBranchs

branch (MkBranchOpt [branchName]) = preCheck $ do
    Base.branch branchName "HEAD"

branch (MkBranchOpt (branchName:startPoint:xs)) = preCheck $ do
    Base.branch branchName startPoint

data StatusOpt = MkStatusOpt 

status :: StatusOpt -> IO ()
status _ = preCheck $ do
    Base.status

data ResetOpt = MkResetOpt [String] Base.ResetMode

reset :: ResetOpt -> IO ()
reset (MkResetOpt (oid:xs) mode) = preCheck $ do
    Base.reset oid mode

reset _ = preCheck $ do
    hPutStrLn stderr "Oid cannot be empty!"


data ShowOpt = MkShowOpt [String]

showCommit :: ShowOpt -> IO ()
showCommit (MkShowOpt (oid:xs)) = preCheck $ do
    Base.showCommit oid

showCommit _ = preCheck $ do
    hPutStrLn stderr "Oid cannot be empty!"