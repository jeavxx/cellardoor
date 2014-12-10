{-# LANGUAGE OverloadedStrings, GeneralizedNewtypeDeriving #-}
module Main where

import Control.Applicative          (Applicative)
import Control.Monad
import Control.Monad.Trans          (liftIO)
import Control.Monad.Reader         (ReaderT, runReaderT, MonadReader, asks)
import Control.Monad.Except
import Data.Maybe                   (maybe)
import System.Exit                  (exitFailure)
import System.Environment           (getExecutablePath)
import System.Posix.Files
import System.Posix.Process         (executeFile)
import System.Posix.Types           (UserID, FileMode)
import System.Posix.User

import HsShellScript
import HsShellScript.Args
import HsShellScript.Paths
import Database.HDBC
import Database.HDBC.Sqlite3        (connectSqlite3)

data CellarConf = CellarConf
        { scriptName      :: String
        , scriptArgs      :: [String]
        , dbfile          :: String
        }
    deriving Show

newtype CellarMonad a = CM {
    runC :: ExceptT String (ReaderT CellarConf IO) a
} deriving (Functor, Applicative, Monad, MonadIO,
            MonadReader CellarConf, MonadError String)

runCellar :: CellarMonad a -> CellarConf -> IO (Either String a)
runCellar m c = runReaderT (runExceptT (runC m)) c


main :: IO ()
main = mainwrapper $ getConf >>= runCellar main' >> return ()


main' :: CellarMonad ()
main' = do
        asks dbfile   >>= ensureExists >>= checkPermissions
        getScriptPath >>= ensureExists >>= checkPermissions >>= runScriptAsRoot
    `catchError` fmap liftIO errorExit


-- | Print an error message (in red) to stderr and exit
errorExit :: String -> IO a
errorExit msg = errm msg >> exitFailure


-- | SUID to root and execute the requested file
runScriptAsRoot :: FilePath -> CellarMonad ()
runScriptAsRoot f = do
    args <- asks scriptArgs
    liftIO $ setUserID 0
    liftIO $ executeFile f False args Nothing


-- | Gather configuration data from command line / environment
getConf :: IO CellarConf
getConf = do
    args <- getargs_ordered "cellardoor: run a script from the suid db"
            [script, db, direct]
    cellardb <- findCellar $ optarg_req args db
    case cellardb of
        Nothing  -> errorExit "ERROR: couldn't find cellar"
        Just cdb ->
            return $ CellarConf { scriptName = reqarg_req args script
                                , scriptArgs = args_req args direct
                                , dbfile     = cdb  }
  where
    script = argdesc [ desc_argname "script"
                     , desc_description "Name of the script to execute"
                     , desc_short 'e'
                     , desc_long "exec"
                     , desc_value_required
                     , desc_once]
    db     = argdesc [ desc_argname "database"
                     , desc_description "Path to alternative cellar"
                     , desc_short 'd'
                     , desc_long "database"
                     , desc_value_required
                     , desc_at_most_once ]
    direct = argdesc [ desc_description "Arguments to pass to the script"
                     , desc_direct
                     , desc_any_times ]


-- | Find the cellar database: If a database path is passed in, just use that.
-- If not, check a list of default locations and use the first one we find.
findCellar :: Maybe FilePath -> IO (Maybe FilePath)
findCellar (Just f) = return $ Just f
findCellar Nothing = do
    realUser <- getRealUserID >>= getUserEntryForID
    execpath <- getExecutablePath
    let execdir = dir_part execpath
        homedir = homeDirectory realUser
        defaults = [ unslice_path [ homedir, ".cellar" ]
                   , unslice_path [ execdir, "cellar" ]
                   , unslice_path [ execdir, ".cellar" ]
                   , "/etc/cellar" ]
    firstExisting defaults
  where
    firstExisting []     = return Nothing
    firstExisting (p:ps) = fileExist p >>= \exists ->
        if exists
            then return $ Just p
            else firstExisting ps


-- | Look up the path for the script that's been requested in the database
getScriptPath :: CellarMonad FilePath
getScriptPath = do
    sname <- asks scriptName
    conn  <- asks dbfile >>= fmap liftIO connectSqlite3
    rows  <- liftIO $ quickQuery' conn
                "SELECT path FROM scripts WHERE name = ?" [toSql sname]
    case concat rows of
        []    -> throwError ("ERROR: no such script in cellar: " ++ sname)
        (x:_) -> return $ fromSql x


-- | Throw an error if the file can't be found. Otherwise, just return the path.
ensureExists :: FilePath -> CellarMonad FilePath
ensureExists f = do
    exists <- liftIO $ fileExist f
    if (exists)
        then return f
        else throwError ("ERROR: file could not be found: " ++ f)


-- | Throw an error if the file has a non-root owner, or can be written by
-- group or other. Otherwise, just return the path.
checkPermissions :: FilePath -> CellarMonad FilePath
checkPermissions f = do
    stats <- liftIO $ getFileStatus f
    if (permissionsOk stats)
        then return f
        else throwError ("ERROR: lax permissions on file " ++ f)
  where
    permissionsOk f' = isRoot (fileOwner f') &&
                       notGroupOrWorldWritable (fileMode f')
    isRoot           = (== 0)
    notGroupOrWorldWritable mode = intersectFileModes
            mode (unionFileModes groupWriteMode otherWriteMode)
            == nullFileMode
