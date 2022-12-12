{-# LANGUAGE OverloadedStrings #-}

module Data
    ( hashObject
    , getObject
    , setHEAD
    , getHEAD
    , setRef
    , getRef
    , ObjType(..)
    , getObjType
    , toObjType
    , Obj(..)
    , Ref(..)
    , headRef
    , mkTagsRef
    , mkHeadsRef
) where

import           Const
import Control.Monad ( forM, when, MonadPlus(mzero) )
import           Data.ByteString      as BS
import qualified Data.ByteString.UTF8 as Utf8
import           System.Directory     (createDirectoryIfMissing,
                                    doesDirectoryExist, doesFileExist,
                                    getDirectoryContents)
import           System.Exit          (exitFailure)
import           System.FilePath      ((</>))
import           System.IO            (hPutStrLn, stderr)
import           Text.Printf          (printf)
import           Util
import Control.Exception (try, SomeException (SomeException))
import Control.Monad.Trans.Maybe (MaybeT (..))
import Control.Monad.Trans.Class ( MonadTrans(lift) )
import Control.Applicative ((<|>))
import System.FilePath.Posix (takeDirectory)

data ObjType = Blob | Tree | Commit deriving(Eq, Ord, Show)

data Obj = MkObj ObjType ByteString

newtype Ref = MkRef FilePath

data RefObj 
    = MkSymbolic Ref
    | MkDereference Ref ByteString
    | MkDirect ByteString

headRef = MkRef "HEAD"
mkTagsRef tagName = MkRef ("refs" </> "tags" </> tagName)
mkHeadsRef tagName = MkRef ("refs" </> "heads" </> tagName)

hashObject :: Obj -> IO ByteString
hashObject (MkObj objType fileContent) = do
    let content = getObjType objType <> "\0" <> fileContent
    let hash = toHexHash content
    createDirectoryIfMissing False objectsDir
    BS.writeFile (objectsDir </> hash) content
    pure $ Utf8.fromString hash

getObjType :: ObjType -> ByteString
getObjType Blob = "blob"
getObjType Tree = "tree"
getObjType Commit = "commit"

toObjType :: ByteString -> ObjType
toObjType "blob" = Blob
toObjType "tree" = Tree
toObjType "commit" = Commit
toObjType _      = Blob

getObject :: String -> IO (Maybe Obj)
getObject hash = do
    let file = objectsDir </> hash
    exists <- doesFileExist file
    if exists then do
        bs <- BS.readFile file
        let (fileType, content) = breakSubstring "\0" bs
        pure . Just $ MkObj (toObjType fileType) (BS.drop 1 content)
    else pure Nothing

getRef :: Ref -> Bool -> MaybeT IO RefObj
getRef (MkRef path) deref
    =   getRef' deref (MkRef $ "refs" </> "tags" </> path)
    <|> getRef' deref (MkRef $ "refs" </> "heads" </> path)
    <|> getRef' deref (MkRef $ "refs" </> path)
    <|> getRef' deref (MkRef $ path)

    where
        getRef' True ref = getDeRef ref
        getRef' False ref = do
            val <- getRefVal ref
            let (t, v) = breakSubstring ": " val
            if t == "ref" then pure $ MkSymbolic (MkRef . Utf8.toString . BS.drop 2 $ v)
            else pure $ MkDirect val
        getDeRef :: Ref -> MaybeT IO RefObj
        getDeRef ref = do
            val <- getRefVal ref
            let (t, v) = breakSubstring ": " val
            if t == "ref" then do
                refObj <- getDeRef (MkRef . Utf8.toString . BS.drop 2 $ v)
                pure $ case refObj of
                    MkDirect hash -> MkDereference ref hash
                    MkDereference _ hash -> MkDereference ref hash
                    a -> a
            else pure $ MkDirect val
        getRefVal :: Ref -> MaybeT IO ByteString
        getRefVal (MkRef path) = do
            exists <- lift $ doesFileExist (repoDir </> path)
            if exists then do
                ei <- lift $ try (BS.readFile path) :: MaybeT IO (Either SomeException ByteString)
                case ei of
                    Left e -> mzero
                    Right v -> pure v
            else mzero

setRef :: Ref -> RefObj -> IO ()
setRef (MkRef path) refObj = do
    let file = repoDir </> path
    let dir = takeDirectory file
    createDirectoryIfMissing True dir
    BS.writeFile file (toContent refObj)
    where
        toContent :: RefObj -> ByteString
        toContent (MkDirect hash) = hash
        toContent (MkDereference _ hash) = hash
        toContent (MkSymbolic (MkRef ref)) = "ref: " <> Utf8.fromString ref

setHEAD :: ByteString -> IO ()
setHEAD = setRef headRef . MkDirect

getHEAD :: MaybeT IO ByteString
getHEAD = do
    refObj <- getRef headRef True
    pure $ case refObj of
        MkDirect hash -> hash
        MkDereference _ hash -> hash
        MkSymbolic r -> error "Error, head"
