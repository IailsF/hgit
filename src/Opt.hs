module Opt(
    CmdOpts(..),
    execParser
) where

import qualified Options.Applicative
import Options.Applicative hiding (execParser)
import qualified Cmd.HashObject as HashObject
import Options.Applicative.Types (ReadM(ReadM))
import Data.Functor ((<&>))

data CmdOpts
  = Init
  | HashObject !HashObject.Opt

parserInfo :: ParserInfo CmdOpts
parserInfo = info (helper <*> cmdParser)
  ( fullDesc
  <> header "hgit - DIY Git in Haskell" )

cmdParser :: Parser CmdOpts
cmdParser = hsubparser (
    command "init" (info initCmdParser (progDesc "Init repository"))
    <> command "hash-object" (info hashObjectCmdParser (progDesc "hash object"))
  )

initCmdParser :: Parser CmdOpts
initCmdParser = pure Init

hashObjectCmdParser :: Parser CmdOpts
hashObjectCmdParser = HashObject <$> argument (str <&> HashObject.Opt) (metavar "FILE")

execParser :: IO CmdOpts
execParser = Options.Applicative.execParser parserInfo