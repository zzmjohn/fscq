{-# LANGUAGE RankNTypes, MagicHash #-}

module Main where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC8
import qualified System.Directory
import Foreign.C.Error
import System.Posix.Types
import System.Posix.Files
import System.Posix.IO
import System.FilePath.Posix
import System.IO
import System.Exit
import Word
import Disk
import Prog
import Fuse
import Data.IORef
import qualified Interpreter as I
import qualified AsyncFS
import qualified Log
import FSLayout
import qualified DirName
import System.Environment
import Inode
import Control.Concurrent.MVar
import Text.Printf
import qualified System.Process
import qualified Data.List
import AsyncDisk
import Control.Monad
import qualified Errno
import Options

-- Handle type for open files; we will use the inode number
type HT = Integer

data FscqOptions = FscqOptions
  { optVerboseFuse :: Bool
  , optCachesize :: Integer
  , optVerboseInterpret :: Bool }

instance Options FscqOptions where
  defineOptions = pure FscqOptions
    <*> simpleOption "verbose-fuse" False
    "Log each FUSE operation"
    <*> simpleOption "cachesize" 100000
    "Maximum number of cache entries"
    <*> simpleOption "verbose-interpret" False
    "Log each interpreter operation"

interpreterOptions :: FscqOptions -> I.Options
interpreterOptions (FscqOptions _ _ verboseInterpret) =
  I.Options verboseInterpret

debug :: FscqOptions -> String -> IO ()
debug opts msg =
  if optVerboseFuse opts then
    putStrLn msg
  else
    return ()

debugStart :: Show a => FscqOptions -> String -> a -> IO ()
debugStart opts op msg = debug opts $ op ++ ": " ++ (show msg)

debugMore :: Show a => FscqOptions -> a -> IO ()
debugMore opts msg = debug opts $ " .. " ++ (show msg)

-- File system configuration
nDataBitmaps :: Integer
nDataBitmaps = 1
nInodeBitmaps :: Integer
nInodeBitmaps = 1
nDescrBlocks :: Integer
nDescrBlocks = 64

type MSCS = (Bool, Log.LOG__Coq_memstate)
type FSprog a = (MSCS -> Prog.Coq_prog (MSCS, a))
type FSrunner = forall a. FSprog a -> IO a
doFScall :: FscqOptions -> DiskState -> IORef MSCS -> FSrunner
doFScall opts ds ref f = do
  s <- readIORef ref
  (s', r) <- I.run (interpreterOptions opts) ds $ f s
  writeIORef ref s'
  return r

-- Get parsed options and remaining arguments
--
-- Errors out if option parsing fails, and handles --help by printing options
-- and exiting.
getOptions :: IO (FscqOptions, [String])
getOptions = do
  args <- getArgs
  let parsed = parseOptions args
  case parsedOptions parsed of
    Just opts -> return (opts, parsedArguments parsed)
    Nothing -> case parsedError parsed of
      Just err -> do
        hPutStrLn stderr err
        hPutStrLn stderr (parsedHelp parsed)
        exitFailure
      Nothing -> do
        putStrLn (parsedHelp parsed)
        exitSuccess

main :: IO ()
main = do
  (opts, args) <- getOptions
  case args of
    fn:rest -> run_fuse opts fn rest
    _ -> putStrLn $ "Usage: fuse disk -f /tmp/ft"

run_fuse :: FscqOptions -> String -> [String] -> IO()
run_fuse opts disk_fn fuse_args = do
  fileExists <- System.Directory.doesFileExist disk_fn
  ds <- case disk_fn of
    "/tmp/crashlog.img" -> init_disk_crashlog disk_fn
    _ -> init_disk disk_fn
  (s, fsxp) <- if fileExists
  then
    do
      putStrLn $ "Recovering file system"
      res <- I.run (interpreterOptions opts) ds $ AsyncFS._AFS__recover (optCachesize opts)
      case res of
        Errno.Err _ -> error $ "recovery failed; not an fscq fs?"
        Errno.OK (s, fsxp) -> do
          return (s, fsxp)
  else
    do
      putStrLn $ "Initializing file system"
      res <- I.run (interpreterOptions opts) ds $ AsyncFS._AFS__mkfs (optCachesize opts) nDataBitmaps nInodeBitmaps nDescrBlocks
      case res of
        Errno.Err _ -> error $ "mkfs failed"
        Errno.OK (s, fsxp) -> do
          set_nblocks_disk ds $ fromIntegral $ coq_FSXPMaxBlock fsxp
          return (s, fsxp)
  putStrLn $ "Starting file system, " ++ (show $ coq_FSXPMaxBlock fsxp) ++ " blocks"
  ref <- newIORef s
  m_fsxp <- newMVar fsxp
  fuseRun "fscq" fuse_args (fscqFSOps opts disk_fn ds (doFScall opts ds ref) m_fsxp) defaultExceptionHandler

-- See the HFuse API docs at:
-- https://hackage.haskell.org/package/HFuse-0.2.1/docs/System-Fuse.html
fscqFSOps :: FscqOptions -> String -> DiskState -> FSrunner -> MVar Coq_fs_xparams -> FuseOperations HT
fscqFSOps opts fn ds fr m_fsxp = defaultFuseOps
  { fuseGetFileStat = fscqGetFileStat opts fr m_fsxp
  , fuseOpen = fscqOpen opts fr m_fsxp
  , fuseCreateDevice = fscqCreate opts fr m_fsxp
  , fuseCreateDirectory = fscqCreateDir opts fr m_fsxp
  , fuseRemoveLink = fscqUnlink opts fr m_fsxp
  , fuseRemoveDirectory = fscqUnlink opts fr m_fsxp
  , fuseRead = fscqRead opts ds fr m_fsxp
  , fuseWrite = fscqWrite opts fr m_fsxp
  , fuseSetFileSize = fscqSetFileSize opts fr m_fsxp
  , fuseOpenDirectory = fscqOpenDirectory opts fr m_fsxp
  , fuseReadDirectory = fscqReadDirectory opts fr m_fsxp
  , fuseGetFileSystemStats = fscqGetFileSystemStats fr m_fsxp
  , fuseDestroy = fscqDestroy ds fn fr m_fsxp
  , fuseSetFileTimes = fscqSetFileTimes
  , fuseRename = fscqRename opts fr m_fsxp
  , fuseSetFileMode = fscqChmod
  , fuseSynchronizeFile = fscqSyncFile opts fr m_fsxp
  , fuseSynchronizeDirectory = fscqSyncDir opts fr m_fsxp
  }

applyFlushgroup :: DiskState -> [(Integer, Coq_word)] -> IO ()
applyFlushgroup _ [] = return ()
applyFlushgroup ds ((a, v) : rest) = do
  applyFlushgroup ds rest
  write_disk ds a v

applyFlushgroups :: DiskState -> [[(Integer, Coq_word)]] -> IO ()
applyFlushgroups _ [] = return ()
applyFlushgroups ds (flushgroup : rest) = do
  applyFlushgroups ds rest
  applyFlushgroup ds flushgroup

materializeFlushgroups :: IORef Integer -> [[(Integer, Coq_word)]] -> IO ()
materializeFlushgroups idxref groups = do
  idx <- readIORef idxref
  writeIORef idxref (idx+1)
  _ <- System.Process.system $ printf "cp --sparse=always /tmp/crashlog.img /tmp/crashlog-%06d.img" idx
  ds <- init_disk $ printf "/tmp/crashlog-%06d.img" idx
  applyFlushgroups ds groups
  _ <- close_disk ds
  return ()

writeSubsets' :: [[(Integer, a)]] -> [[(Integer, a)]]
writeSubsets' [] = [[]]
writeSubsets' (heads : tails) =
    tailsubsets ++ (concat $ map (\ts -> map (\hd -> hd : ts) heads) tailsubsets)
  where
    tailsubsets = writeSubsets' tails

writeSubsets :: [(Integer, a)] -> [[(Integer, a)]]
writeSubsets writes = writeSubsets' addrWrites
  where
    addrWrites = Data.List.groupBy sameaddr writes
    sameaddr (x, _) (y, _) = (x == y)

materializeCrashes :: IORef Integer -> [[(Integer, Coq_word)]] -> IO ()
materializeCrashes idxref [] = materializeFlushgroups idxref []
materializeCrashes idxref (lastgroup : othergroups) = do
  materializeCrashes idxref othergroups
  mapM_ (\lastsubset -> materializeFlushgroups idxref (lastsubset : othergroups)) $ writeSubsets lastgroup

errnoToPosix :: Errno.Errno -> Errno
errnoToPosix Errno.ELOGOVERFLOW = eIO
errnoToPosix Errno.ENOTDIR      = eNOTDIR
errnoToPosix Errno.EISDIR       = eISDIR
errnoToPosix Errno.ENOENT       = eNOENT
errnoToPosix Errno.EFBIG        = eFBIG
errnoToPosix Errno.ENAMETOOLONG = eNAMETOOLONG
errnoToPosix Errno.EEXIST       = eEXIST
errnoToPosix Errno.ENOSPCBLOCK  = eNOSPC
errnoToPosix Errno.ENOSPCINODE  = eNOSPC
errnoToPosix Errno.ENOTEMPTY    = eNOTEMPTY
errnoToPosix Errno.EINVAL       = eINVAL

instance Show Errno.Errno where
  show Errno.ELOGOVERFLOW = "ELOGOVERFLOW"
  show Errno.ENOTDIR      = "ENOTDIR"
  show Errno.EISDIR       = "EISDIR"
  show Errno.ENOENT       = "ENOENT"
  show Errno.EFBIG        = "EFBIG"
  show Errno.ENAMETOOLONG = "ENAMETOOLONG"
  show Errno.EEXIST       = "EEXIST"
  show Errno.ENOSPCBLOCK  = "ENOSPCBLOCK"
  show Errno.ENOSPCINODE  = "ENOSPCINODE"
  show Errno.ENOTEMPTY    = "ENOTEMPTY"
  show Errno.EINVAL       = "EINVAL"

instance Show t => Show (Errno.Coq_res t) where
  show (Errno.OK v) = show v
  show (Errno.Err e) = show e

fscqDestroy :: DiskState -> String -> FSrunner -> MVar Coq_fs_xparams -> IO ()
fscqDestroy ds disk_fn fr m_fsxp  = withMVar m_fsxp $ \fsxp -> do
  _ <- fr $ AsyncFS._AFS__umount fsxp
  stats <- close_disk ds
  print_stats stats
  case disk_fn of
    "/tmp/crashlog.img" -> do
      flushgroups <- get_flush_log ds
      putStrLn $ "Number of flush groups: " ++ (show (length flushgroups))
      idxref <- newIORef 0
      materializeCrashes idxref flushgroups
    _ -> return ()

dirStat :: FuseContext -> FileStat
dirStat ctx = FileStat
  { statEntryType = Directory
  , statFileMode = foldr1 unionFileModes
                     [ ownerReadMode, ownerWriteMode, ownerExecuteMode
                     , groupReadMode, groupExecuteMode
                     , otherReadMode, otherExecuteMode
                     ]
  , statLinkCount = 2
  , statFileOwner = fuseCtxUserID ctx
  , statFileGroup = fuseCtxGroupID ctx
  , statSpecialDeviceID = 0
  , statFileSize = 4096
  , statBlocks = 1
  , statAccessTime = 0
  , statModificationTime = 0
  , statStatusChangeTime = 0
  }

attrToType :: INODE__Coq_iattr -> EntryType
attrToType attr =
  if t == 0 then RegularFile else Socket
  where t = wordToNat 32 $ _INODE__coq_AType attr

fileStat :: FuseContext -> INODE__Coq_iattr -> FileStat
fileStat ctx attr = FileStat
  { statEntryType = attrToType attr
  , statFileMode = foldr1 unionFileModes
                     [ ownerReadMode, ownerWriteMode, ownerExecuteMode
                     , groupReadMode, groupWriteMode, groupExecuteMode
                     , otherReadMode, otherWriteMode, otherExecuteMode
                     ]
  , statLinkCount = 1
  , statFileOwner = fuseCtxUserID ctx
  , statFileGroup = fuseCtxGroupID ctx
  , statSpecialDeviceID = 0
  , statFileSize = fromIntegral $ wordToNat 64 $ _INODE__coq_ABytes attr
  , statBlocks = 1
  , statAccessTime = 0
  , statModificationTime = fromIntegral $ wordToNat 32 $ _INODE__coq_AMTime attr
  , statStatusChangeTime = 0
  }

fscqGetFileStat :: FscqOptions -> FSrunner -> MVar Coq_fs_xparams -> FilePath -> IO (Either Errno FileStat)
fscqGetFileStat opts fr m_fsxp (_:path)
  | path == "stats" = do
    ctx <- getFuseContext
    return $ Right $ fileStat ctx $ _INODE__iattr_upd _INODE__iattr0 $ INODE__UBytes $ W 4096
  | otherwise = withMVar m_fsxp $ \fsxp -> do
  debugStart opts "STAT" path
  nameparts <- return $ splitDirectories path
  (r, ()) <- fr $ AsyncFS._AFS__lookup fsxp (coq_FSXPRootInum fsxp) nameparts
  debugMore opts r
  case r of
    Errno.Err e -> return $ Left $ errnoToPosix e
    Errno.OK (inum, isdir)
      | isdir -> do
        ctx <- getFuseContext
        return $ Right $ dirStat ctx
      | otherwise -> do
        (attr, ()) <- fr $ AsyncFS._AFS__file_get_attr fsxp inum
        ctx <- getFuseContext
        return $ Right $ fileStat ctx attr
fscqGetFileStat _ _ _ _ = return $ Left eNOENT

fscqOpenDirectory :: FscqOptions -> FSrunner -> MVar Coq_fs_xparams -> FilePath -> IO Errno
fscqOpenDirectory opts fr m_fsxp (_:path) = withMVar m_fsxp $ \fsxp -> do
  debugStart opts "OPENDIR" path
  nameparts <- return $ splitDirectories path
  (r, ()) <- fr $ AsyncFS._AFS__lookup fsxp (coq_FSXPRootInum fsxp) nameparts
  debugMore opts r
  case r of
    Errno.Err e -> return $ errnoToPosix e
    Errno.OK (_, isdir)
      | isdir -> return eOK
      | otherwise -> return eNOTDIR
fscqOpenDirectory _ _ _ "" = return eNOENT

fscqReadDirectory :: FscqOptions -> FSrunner -> MVar Coq_fs_xparams -> FilePath -> IO (Either Errno [(FilePath, FileStat)])
fscqReadDirectory opts fr m_fsxp (_:path) = withMVar m_fsxp $ \fsxp -> do
  debugStart opts "READDIR" path
  ctx <- getFuseContext
  nameparts <- return $ splitDirectories path
  (r, ()) <- fr $ AsyncFS._AFS__lookup fsxp (coq_FSXPRootInum fsxp) nameparts
  debugMore opts r
  case r of
    Errno.Err e -> return $ Left $ errnoToPosix e
    Errno.OK (dnum, isdir)
      | isdir -> do
        (files, ()) <- fr $ AsyncFS._AFS__readdir fsxp dnum
        files_stat <- mapM (mkstat fsxp ctx) files
        return $ Right $ [(".",          dirStat ctx)
                         ,("..",         dirStat ctx)
                         ] ++ files_stat
      | otherwise -> return $ Left $ eNOTDIR
  where
    mkstat fsxp ctx (fn, (inum, isdir))
      | isdir = return $ (fn, dirStat ctx)
      | otherwise = do
        (attr, ()) <- fr $ AsyncFS._AFS__file_get_attr fsxp inum
        return $ (fn, fileStat ctx attr)

fscqReadDirectory _ _ _ _ = return (Left (eNOENT))

fscqOpen :: FscqOptions -> FSrunner -> MVar Coq_fs_xparams -> FilePath -> OpenMode -> OpenFileFlags -> IO (Either Errno HT)
fscqOpen opts fr m_fsxp (_:path) _ _
  | path == "stats" = return $ Right 0
  | otherwise = withMVar m_fsxp $ \fsxp -> do
  debugStart opts "OPEN" path
  nameparts <- return $ splitDirectories path
  (r, ()) <- fr $ AsyncFS._AFS__lookup fsxp (coq_FSXPRootInum fsxp) nameparts
  debugMore opts r
  case r of
    Errno.Err e -> return $ Left $ errnoToPosix e
    Errno.OK (inum, isdir)
      | isdir -> return $ Left eISDIR
      | otherwise -> return $ Right $ inum
fscqOpen _ _ _ _ _ _ = return $ Left eIO

splitDirsFile :: String -> ([String], String)
splitDirsFile path = (init parts, last parts)
  where parts = splitDirectories path

fscqCreate :: FscqOptions -> FSrunner -> MVar Coq_fs_xparams -> FilePath -> EntryType -> FileMode -> DeviceID -> IO Errno
fscqCreate opts fr m_fsxp (_:path) entrytype _ _ = withMVar m_fsxp $ \fsxp -> do
  debugStart opts "CREATE" path
  (dirparts, filename) <- return $ splitDirsFile path
  (rd, ()) <- fr $ AsyncFS._AFS__lookup fsxp (coq_FSXPRootInum fsxp) dirparts
  debugMore opts rd
  case rd of
    Errno.Err e -> return $ errnoToPosix e
    Errno.OK (dnum, isdir)
      | isdir -> do
        (r, ()) <- case entrytype of
          RegularFile -> fr $ AsyncFS._AFS__create fsxp dnum filename
          Socket -> fr $ AsyncFS._AFS__mksock fsxp dnum filename
          _ -> return (Errno.Err Errno.EINVAL, ())
        debugMore opts r
        case r of
          Errno.Err e -> return $ errnoToPosix e
          Errno.OK _ -> return eOK
      | otherwise -> return eNOTDIR
fscqCreate _ _ _ _ _ _ _ = return eOPNOTSUPP

fscqCreateDir :: FscqOptions -> FSrunner -> MVar Coq_fs_xparams -> FilePath -> FileMode -> IO Errno
fscqCreateDir opts fr m_fsxp (_:path) _ = withMVar m_fsxp $ \fsxp -> do
  debugStart opts "MKDIR" path
  (dirparts, filename) <- return $ splitDirsFile path
  (rd, ()) <- fr $ AsyncFS._AFS__lookup fsxp (coq_FSXPRootInum fsxp) dirparts
  debugMore opts rd
  case rd of
    Errno.Err e -> return $ errnoToPosix e
    Errno.OK (dnum, isdir)
      | isdir -> do
        (r, ()) <- fr $ AsyncFS._AFS__mkdir fsxp dnum filename
        debugMore opts r
        case r of
          Errno.Err e -> return $ errnoToPosix e
          Errno.OK _ -> return eOK
      | otherwise -> return eNOTDIR
fscqCreateDir _ _ _ _ _ = return eOPNOTSUPP

fscqUnlink :: FscqOptions -> FSrunner -> MVar Coq_fs_xparams -> FilePath -> IO Errno
fscqUnlink opts fr m_fsxp (_:path) = withMVar m_fsxp $ \fsxp -> do
  debugStart opts "UNLINK" path
  (dirparts, filename) <- return $ splitDirsFile path
  (rd, ()) <- fr $ AsyncFS._AFS__lookup fsxp (coq_FSXPRootInum fsxp) dirparts
  debugMore opts rd
  case rd of
    Errno.Err e -> return $ errnoToPosix e
    Errno.OK (dnum, isdir)
      | isdir -> do
        (r, ()) <- fr $ AsyncFS._AFS__delete fsxp dnum filename
        debugMore opts r
        case r of
          Errno.OK _ -> return eOK
          Errno.Err e -> return $ errnoToPosix e
      | otherwise -> return eNOTDIR
fscqUnlink _ _ _ _ = return eOPNOTSUPP

-- Wrappers for converting Coq_word to/from ByteString, with
-- the help of i2buf and buf2i from hslib/Disk.
blocksize :: Integer
blocksize = _Valulen__valulen `div` 8

data BlockRange =
  BR !Integer !Integer !Integer   -- blocknumber, offset-in-block, count-from-offset

compute_ranges_int :: Integer -> Integer -> [BlockRange]
compute_ranges_int off count = map mkrange $ zip3 blocknums startoffs endoffs
  where
    mkrange (blk, startoff, endoff) = BR blk startoff (endoff-startoff)
    blocknums = [off `div` blocksize .. (off + count - 1) `div` blocksize]
    startoffs = [off `mod` blocksize] ++ replicate (length blocknums - 1) 0
    endoffs = replicate (length blocknums - 1) blocksize ++ [(off + count - 1) `mod` blocksize + 1]

compute_ranges :: FileOffset -> ByteCount -> [BlockRange]
compute_ranges off count =
  compute_ranges_int (fromIntegral off) (fromIntegral count)

fscqRead :: FscqOptions -> DiskState -> FSrunner -> MVar Coq_fs_xparams -> FilePath -> HT -> ByteCount -> FileOffset -> IO (Either Errno BS.ByteString)
fscqRead opts ds fr m_fsxp (_:path) inum byteCount offset
  | path == "stats" = do
    Stats r w s <- get_stats ds
    clear_stats ds
    statbuf <- return $ BSC8.pack $
      "Reads:  " ++ (show r) ++ "\n" ++
      "Writes: " ++ (show w) ++ "\n" ++
      "Syncs:  " ++ (show s) ++ "\n"
    return $ Right statbuf
  | otherwise = withMVar m_fsxp $ \fsxp -> do
  debugStart opts "READ" (inum, path)
  (wlen, ()) <- fr $ AsyncFS._AFS__file_get_sz fsxp inum
  len <- return $ fromIntegral $ wordToNat 64 wlen
  offset' <- return $ min offset len
  byteCount' <- return $ min byteCount $ (fromIntegral len) - (fromIntegral offset')
  pieces <- mapM (read_piece fsxp) $ compute_ranges offset' byteCount'
  r <- return $ BS.concat pieces
  debugMore opts $ BS.length r
  return $ Right r

  where
    read_piece fsxp (BR blk off count) = do
      (W w, ()) <- fr $ AsyncFS._AFS__read_fblock fsxp inum blk
      bs <- i2bs w 4096
      return $ BS.take (fromIntegral count) $ BS.drop (fromIntegral off) bs

fscqRead _ _ _ _ [] _ _ _ = do
  return $ Left $ eIO

compute_range_pieces :: FileOffset -> BS.ByteString -> [(BlockRange, BS.ByteString)]
compute_range_pieces off buf = zip ranges pieces
  where
    ranges = compute_ranges_int (fromIntegral off) $ fromIntegral $ BS.length buf
    pieces = map getpiece ranges
    getpiece (BR blk boff bcount) = BS.take (fromIntegral bcount) $ BS.drop (fromIntegral bufoff) buf
      where bufoff = (blk * blocksize) + boff - (fromIntegral off)

data WriteState =
   WriteOK !ByteCount
 | WriteErr !ByteCount

fscqWrite :: FscqOptions -> FSrunner -> MVar Coq_fs_xparams -> FilePath -> HT -> BS.ByteString -> FileOffset -> IO (Either Errno ByteCount)
fscqWrite opts fr m_fsxp path inum bs offset = withMVar m_fsxp $ \fsxp -> do
  debugStart opts "WRITE" (path, inum)
  (wlen, ()) <- fr $ AsyncFS._AFS__file_get_sz fsxp inum
  len <- return $ fromIntegral $ wordToNat 64 wlen
  endpos <- return $ (fromIntegral offset) + (fromIntegral (BS.length bs))
  okspc <- if len < endpos then do
    (ok, _) <- fr $ AsyncFS._AFS__file_truncate fsxp inum ((endpos + 4095) `div` 4096)
    return ok
  else
    return $ Errno.OK ()
  case okspc of
    Errno.OK _ -> do
      r <- foldM (write_piece fsxp len) (WriteOK 0) (compute_range_pieces offset bs)
      case r of
        WriteOK c -> do
          okspc2 <- if len < endpos then do
            (ok, _) <- fr $ AsyncFS._AFS__file_set_sz fsxp inum (W endpos)
            return ok
          else
            return True
          if okspc2 then
              return $ Right c
            else
              return $ Left eNOSPC
        WriteErr c ->
          if c == 0 then
            return $ Left eIO
          else
            return $ Right c
    Errno.Err e -> do
      return $ Left $ errnoToPosix e
  where
    write_piece _ _ (WriteErr c) _ = return $ WriteErr c
    write_piece fsxp init_len (WriteOK c) (BR blk off cnt, piece_bs) = do
      (W w, ()) <- if blk*blocksize < init_len then
          fr $ AsyncFS._AFS__read_fblock fsxp inum blk
        else
          return $ (W 0, ())
      old_bs <- i2bs w 4096
      new_bs <- return $ BS.append (BS.take (fromIntegral off) old_bs)
                       $ BS.append piece_bs
                       $ BS.drop (fromIntegral $ off + cnt) old_bs
      wnew <- bs2i new_bs
      -- _ <- fr $ AsyncFS._AFS__update_fblock_d fsxp inum blk (W wnew)
      _ <- fr $ AsyncFS._AFS__update_fblock fsxp inum blk (W wnew)
      return $ WriteOK (c + (fromIntegral cnt))

fscqSetFileSize :: FscqOptions -> FSrunner -> MVar Coq_fs_xparams -> FilePath -> FileOffset -> IO Errno
fscqSetFileSize opts fr m_fsxp (_:path) size = withMVar m_fsxp $ \fsxp -> do
  debugStart opts "SETSIZE" (path, size)
  nameparts <- return $ splitDirectories path
  (r, ()) <- fr $ AsyncFS._AFS__lookup fsxp (coq_FSXPRootInum fsxp) nameparts
  debugMore opts r
  case r of
    Errno.Err e -> return $ errnoToPosix e
    Errno.OK (inum, isdir)
      | isdir -> return eISDIR
      | otherwise -> do
        (ok, ()) <- fr $ AsyncFS._AFS__file_set_sz fsxp inum (W64 $ fromIntegral size)
        if ok then
          return eOK
        else
          return eIO
fscqSetFileSize _ _ _ _ _ = return eIO

fscqGetFileSystemStats :: FSrunner -> MVar Coq_fs_xparams -> String -> IO (Either Errno FileSystemStats)
fscqGetFileSystemStats fr m_fsxp _ = withMVar m_fsxp $ \fsxp -> do
  (freeblocks, (freeinodes, ())) <- fr $ AsyncFS._AFS__statfs fsxp
  block_bitmaps <- return $ coq_BmapNBlocks $ coq_FSXPBlockAlloc1 fsxp
  inode_bitmaps <- return $ coq_BmapNBlocks $ coq_FSXPInodeAlloc fsxp
  return $ Right $ FileSystemStats
    { fsStatBlockSize = 4096
    , fsStatBlockCount = 8 * 4096 * (fromIntegral $ block_bitmaps)
    , fsStatBlocksFree = fromIntegral $ freeblocks
    , fsStatBlocksAvailable = fromIntegral $ freeblocks
    , fsStatFileCount = 8 * 4096 * (fromIntegral $ inode_bitmaps)
    , fsStatFilesFree = fromIntegral $ freeinodes
    , fsStatMaxNameLength = fromIntegral DirName._SDIR__namelen
    }

fscqSetFileTimes :: FilePath -> EpochTime -> EpochTime -> IO Errno
fscqSetFileTimes _ _ _ = do
  return eOK

fscqRename :: FscqOptions -> FSrunner -> MVar Coq_fs_xparams -> FilePath -> FilePath -> IO Errno
fscqRename opts fr m_fsxp (_:src) (_:dst) = withMVar m_fsxp $ \fsxp -> do
  debugStart opts "RENAME" (src, dst)
  (srcparts, srcname) <- return $ splitDirsFile src
  (dstparts, dstname) <- return $ splitDirsFile dst
  (r, ()) <- fr $ AsyncFS._AFS__rename fsxp (coq_FSXPRootInum fsxp) srcparts srcname dstparts dstname
  debugMore opts r
  case r of
    Errno.OK _ -> return eOK
    Errno.Err e -> return $ errnoToPosix e
fscqRename _ _ _ _ _ = return eIO

fscqChmod :: FilePath -> FileMode -> IO Errno
fscqChmod _ _ = do
  return eOK

fscqSyncFile :: FscqOptions -> FSrunner -> MVar Coq_fs_xparams -> FilePath -> SyncType -> IO Errno
fscqSyncFile opts fr m_fsxp (_:path) syncType = withMVar m_fsxp $ \fsxp -> do
  debugStart opts "SYNC FILE" path
  nameparts <- return $ splitDirectories path
  (r, ()) <- fr $ AsyncFS._AFS__lookup fsxp (coq_FSXPRootInum fsxp) nameparts
  debugMore opts r
  case r of
    Errno.Err e -> return $ errnoToPosix e
    Errno.OK (inum, _) -> do
      _ <- fr $ AsyncFS._AFS__file_sync fsxp inum
      case syncType of
        DataSync -> return eOK
        FullSync -> do
          _ <- fr $ AsyncFS._AFS__tree_sync fsxp
          return eOK
fscqSyncFile _ _ _ _ _ = return eIO

fscqSyncDir :: FscqOptions -> FSrunner -> MVar Coq_fs_xparams -> FilePath -> SyncType -> IO Errno
fscqSyncDir opts fr m_fsxp (_:path) _ = withMVar m_fsxp $ \fsxp -> do
  debugStart opts "SYNC DIR" path
  _ <- fr $ AsyncFS._AFS__tree_sync fsxp
  return eOK
fscqSyncDir _ _ _ _ _ = return eIO