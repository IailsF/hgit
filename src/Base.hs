{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}

module Base
    (writeTree
    , readObj
    , commit
    , log
    , checkout
    , tag
    , resolveOid
    ) where

import           Const
import Control.Monad ( forM, unless, when, forM_ )
import           Data
import qualified Data.ByteString       as BS
import qualified Data.ByteString.UTF8  as Utf8
import           Data.Foldable         (foldl')
import           Data.List             (intercalate, sort, partition)
import           Data.Maybe            (catMaybes, mapMaybe)
import           System.Directory      (createDirectoryIfMissing,
                                        doesDirectoryExist,
                                        getDirectoryContents, removePathForcibly, doesFileExist)
import           System.Exit           (exitFailure)
import           System.FilePath       ((</>))
import           System.IO             (hPutStrLn, stderr)
import qualified Data.ByteString.Char8 as Char8
import Control.Monad.IO.Class (MonadIO(liftIO))
import Control.Monad.Trans.Class ( MonadTrans(lift) )
import Control.Monad.Trans.Maybe (MaybeT (MaybeT), runMaybeT)
import Util
import Prelude hiding (log)
import Control.Monad (MonadPlus(mzero))
import Control.Applicative ((<|>))

data ParsedObj
    = ParsedBlob BS.ByteString
    | ParsedTree [TreeItem]
    | ParsedCommit CommitHeaders BS.ByteString
    deriving(Show)

data TreeItem = MkTreeItem ObjType BS.ByteString BS.ByteString deriving(Eq, Ord, Show)
data CommitHeader = TreeHeader BS.ByteString | ParentHeader BS.ByteString deriving(Show)
data CommitHeaders = MkCommitHeaders {raw :: [CommitHeader], tree :: BS.ByteString, parent :: Maybe BS.ByteString} deriving(Show)

toParsedObj :: Obj -> ParsedObj
toParsedObj (MkObj Blob bs) = ParsedBlob bs
toParsedObj (MkObj Tree bs) = ParsedTree $ mapMaybe toTreeItem (Utf8.lines bs)
toParsedObj (MkObj Commit bs) = ParsedCommit (toHeaders (mapMaybe toCommitHeader headerLines)) (BS.concat msgLines)
    where
        (headerLines, msgLines) = break ( == "") (Utf8.lines bs)

fromParsedObj :: ParsedObj -> Obj
fromParsedObj (ParsedBlob bs) = MkObj Blob bs
fromParsedObj (ParsedTree items) = MkObj Tree $ (BS.intercalate "\n" . map fromTreeItem) items
fromParsedObj (ParsedCommit MkCommitHeaders{raw=headers} msg) = MkObj Commit (Char8.unlines (map fromCommitHeader headers) <> "\n" <> msg)

fromTreeItem :: TreeItem -> BS.ByteString
fromTreeItem (MkTreeItem objType hash name) = getObjType objType <> " " <> hash <> " " <> name

toTreeItem :: BS.ByteString -> Maybe TreeItem
toTreeItem = parseItems . splitItems
    where
        splitItems = BS.split spaceChar
        parseItems (objType:hash:name:xs) = Just $ MkTreeItem (toObjType objType) hash name
        parseItems _ = Nothing

fromCommitHeader :: CommitHeader -> BS.ByteString
fromCommitHeader (TreeHeader v) = "tree " <> v
fromCommitHeader (ParentHeader v) = "parent " <> v

toCommitHeader :: BS.ByteString -> Maybe CommitHeader
toCommitHeader = parseItems . splitItems
    where
        splitItems = BS.split spaceChar
        parseItems ("tree":value:xs) = Just $ TreeHeader value
        parseItems ("parent":value:xs) = Just $ ParentHeader value
        parseItems _ = Nothing

toHeaders :: [CommitHeader] -> CommitHeaders
toHeaders hs = foldl' put MkCommitHeaders {raw = hs, tree = error "Commit no tree header!", parent = Nothing} hs
    where
        put headers (TreeHeader bs) = headers {tree = bs}
        put headers (ParentHeader bs) = headers {parent = Just bs}

writeTree :: FilePath -> IO BS.ByteString
writeTree dir = do
    when (dir == repoDir) (hPutStrLn stderr "Cannot write repository!" >> exitFailure)
    exists <- doesDirectoryExist dir
    unless exists (hPutStrLn stderr ("Directory " <> dir <> " not exists!") >> exitFailure)
    ds <- getDirectoryContents dir
    paths <- forM (filter validDir ds) $ \e -> do
        let path = dir </> e
        isDir <- doesDirectoryExist path
        if isDir then do
            hash <- writeTree path
            pure $ MkTreeItem Tree hash (Utf8.fromString e)
        else do
            content <- BS.readFile path
            hash <- hashObject (MkObj Blob content)
            pure $ MkTreeItem Blob hash (Utf8.fromString e)
    hashObject (fromParsedObj . ParsedTree $ sort paths)

listFiles :: FilePath -> IO [FilePath]
listFiles root = do
  ds <- getDirectoryContents root
  paths <- forM (filter validDir ds) $ \e -> do
    let path = root </> e
    isDir <- doesDirectoryExist path
    if isDir then listFiles path
    else return [path]
  return (concat paths)

validDir = (`notElem` [".","..",repoDir])

readObj :: String -> IO ()
readObj oid = do
    hashM <- runMaybeT $ resolveOid oid
    case hashM of
        Just hash -> emptyCurrentDir >> readObjWithBase "." (Utf8.toString hash)
        Nothing -> pure ()
    where
        readObjWithBase :: FilePath -> String -> IO ()
        readObjWithBase root hash = do
            obj <- getObject hash
            maybe (hPutStrLn stderr ("Object " <> hash <> " not exists!")) (readObj' root) (toParsedObj <$> obj)

        readObj' :: FilePath -> ParsedObj -> IO ()
        readObj' path (ParsedCommit _ _) = mempty
        readObj' path (ParsedBlob content) = BS.writeFile path content

        readObj' path (ParsedTree items) = do
            createDirectoryIfMissing False path
            let actions = map (readItem path) items
            foldl' (>>) mempty actions
        readItem :: FilePath -> TreeItem -> IO ()
        readItem root (MkTreeItem Commit hash name) = mempty
        readItem root (MkTreeItem Tree hash name) = readObjWithBase (root </> Utf8.toString name) (Utf8.toString hash)
        readItem root (MkTreeItem Blob hash name) = do
            obj <- getObject (Utf8.toString hash)
            maybe (hPutStrLn stderr ("Object " <> Utf8.toString hash <> " not exists!")) (readObj' (root </> Utf8.toString name)) (toParsedObj <$> obj)

emptyCurrentDir :: IO ()
emptyCurrentDir = emptyDir "."
    where
        emptyDir :: FilePath -> IO ()
        emptyDir root = do
            ds <- getDirectoryContents root
            forM_ (filter validDir ds) $ \file -> do
                removePathForcibly file

commit :: String -> IO ()
commit msg = do
    hash <- writeTree "."
    headM <- runMaybeT getHEAD
    let headers = [TreeHeader hash] <> maybe mempty (\head -> [ParentHeader head]) headM
    let comm = ParsedCommit (toHeaders headers) (Utf8.fromString msg)
    commitHash <- hashObject $ fromParsedObj comm
    setHEAD commitHash
    putStrLn . Utf8.toString $ commitHash

getCommit :: String -> MaybeT IO ParsedObj
getCommit hash = do
    objM <- lift $ getObject hash
    let parsedM = toParsedObj <$> objM
    MaybeT . pure $ parsedM

log :: String -> IO ()
log hash = do
    runMaybeT $ do
        comm <- getCommit hash
        printLog hash comm
    pure ()

    where
        printLog :: String -> ParsedObj -> MaybeT IO ()
        printLog hash (ParsedBlob _) = mzero
        printLog hash (ParsedTree _) = mzero
        printLog hash (ParsedCommit headers msg) = do
            lift $ putStrLn ("commit " <> hash <> "\n\n\t" <> Utf8.toString msg <> "\n")
            printParent headers

        printParent :: CommitHeaders -> MaybeT IO ()
        printParent MkCommitHeaders{tree = t, parent = Nothing} = mzero
        printParent MkCommitHeaders{tree = t, parent = Just p} = do
            let pStr = Utf8.toString p
            comm <- getCommit pStr
            printLog pStr comm

checkout :: String -> IO ()
checkout oid = do
    runMaybeT $ do
        hash <- resolveOid oid
        comm <- getCommit (Utf8.toString hash)
        lift $ readCommit comm
        lift $ setHEAD hash
    pure ()
    where
        readCommit :: ParsedObj -> IO ()
        readCommit (ParsedBlob _) = mempty
        readCommit (ParsedTree _) = mempty
        readCommit (ParsedCommit MkCommitHeaders{tree=t} _) = do
            readObj . Utf8.toString $ t

resolveOid :: String -> MaybeT IO BS.ByteString
resolveOid oid = getRef (MkRef oid) <|> objHash oid <|> (lift (hPutStrLn stderr ("Cannot resolve this oid: " <> oid)) >> mzero)
    where
        objHash :: String -> MaybeT IO BS.ByteString
        objHash hash = do
            exists <- lift $ doesFileExist (objectsDir </> hash)
            if exists then pure (Utf8.fromString hash)
            else mzero

tag :: String -> String -> IO ()
tag tagName hash = do
    setRef (mkTagsRef tagName) (Utf8.fromString hash)
