{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE RecordWildCards, NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import           Control.Concurrent
import           Control.Exception (Exception, catch)
import           Control.Monad
import           Control.Monad (void)
import qualified Data.ByteString.Char8 as BSC8
import           Data.IORef
import           Data.List (intercalate)
import           Options
import           System.Exit
import           System.IO (hPutStrLn, stderr)
import           System.Random
import           System.Random.Shuffle (shuffle')

import           Benchmarking
import           BenchmarkingData
import           CfscqFs
import           DataSet
import           DbenchExecute
import           DbenchScript (parseScriptFile)
import           FscqFs
import           Fuse
import           GenericFs
import           MailServerOperations
import           NativeFs
import           ParallelSearch
import           System.Posix.Files (ownerModes)
import           System.Posix.IO (defaultFileFlags)
import           System.Posix.Types (FileOffset)
import           Timings

import           System.Mem (performMajorGC)

data NoOptions = NoOptions {}
instance Options NoOptions where
  defineOptions = pure NoOptions

statfsOp :: ParOptions -> NoOptions -> Filesystem fh -> IO ()
statfsOp _ _ Filesystem{fuseOps=fs} = void $ fuseGetFileSystemStats fs "/"

data ScanDirOptions =
  ScanDirOptions { optScanRoot :: String }
instance Options ScanDirOptions where
  defineOptions = pure ScanDirOptions <*>
    simpleOption "dir" "/"
      "root directory to scan from"

shuffleList :: [a] -> IO [a]
shuffleList xs = shuffle' xs (length xs) <$> getStdGen

readEntireFile :: Filesystem fh -> Maybe FileOffset -> FilePath -> IO ()
readEntireFile Filesystem{fuseOps=fs} msize p = do
  fh <- getResult p =<< fuseOpen fs p ReadOnly defaultFileFlags
  fileSize <- case msize of
    Just s -> return s
    Nothing -> getFileSize fs p
  offsets <- shuffleList [0,4096..fileSize]
  forM_ offsets $ \off ->
    fuseRead fs p fh 4096 off
  closeFile fs p fh

catFiles :: Filesystem fh -> [(FilePath, FileStat)] -> IO ()
catFiles fs es = forM_ es $ \(p, s) -> when (isFile s) $ do
  readEntireFile fs (Just $ statFileSize s) p

catDirOp :: ParOptions -> ScanDirOptions -> Filesystem fh -> IO ()
catDirOp _ ScanDirOptions{..} fs@Filesystem{fuseOps} = do
  entries <- traverseDirectory fuseOps optScanRoot
  catFiles fs entries

traverseDirOp :: ParOptions -> ScanDirOptions -> Filesystem fh -> IO ()
traverseDirOp _ ScanDirOptions{..} Filesystem{fuseOps} =
  void $ traverseDirectory fuseOps optScanRoot

readDirPrepare :: forall fh. ParOptions -> ScanDirOptions -> Filesystem fh -> IO fh
readDirPrepare _ ScanDirOptions{..} Filesystem{fuseOps=fs} =
  getResult optScanRoot =<< fuseOpenDirectory fs optScanRoot

readDirOp :: forall fh. ParOptions -> ScanDirOptions -> Filesystem fh -> fh -> IO ()
readDirOp _ ScanDirOptions{..} Filesystem{fuseOps=fs} dnum =
  void $ fuseReadDirectory fs optScanRoot dnum

data FileOpOptions =
  FileOpOptions { optFile :: String }
instance Options FileOpOptions where
  defineOptions = pure FileOpOptions <*>
    simpleOption "file" "/small"
      "file to operate on"

statOp :: ParOptions -> FileOpOptions -> Filesystem fh -> IO ()
statOp _ FileOpOptions{..} Filesystem{fuseOps=fs} = do
    _ <- fuseGetFileStat fs optFile
    return ()

catFileOp :: ParOptions -> FileOpOptions -> Filesystem fh -> IO ()
catFileOp _ FileOpOptions{..} fs = do
    _ <- readEntireFile fs Nothing optFile
    return ()

openOp :: ParOptions -> FileOpOptions -> Filesystem fh -> IO ()
openOp _ FileOpOptions{..} Filesystem{fuseOps=fs} = do
    inum <- getResult optFile =<< fuseOpen fs optFile ReadOnly defaultFileFlags
    closeFile fs optFile inum
    return ()

data FileOffsetOpOptions =
  FileOffsetOpOptions { optFileName :: String
                      , optFileOffset :: Int }
instance Options FileOffsetOpOptions where
  defineOptions = pure FileOffsetOpOptions
    <*> simpleOption "file" "/large"
      "file to operate on"
    <*> simpleOption "offset" 0
      "offset (in bytes) to read from"

readFilePrepare :: ParOptions -> FileOffsetOpOptions -> Filesystem fh -> IO fh
readFilePrepare _ FileOffsetOpOptions{..} Filesystem{fuseOps=fs} =
  getResult optFileName =<< fuseOpen fs optFileName ReadOnly defaultFileFlags

readFileOp :: ParOptions -> FileOffsetOpOptions -> Filesystem fh -> fh -> IO ()
readFileOp _ FileOffsetOpOptions{..} Filesystem{fuseOps=fs} inum =
  void $ fuseRead fs optFileName inum 4096 (fromIntegral optFileOffset)

type ThreadNum = Int

-- replicateInParallel par iters act runs act in n parallel copies, passing
-- 0..n-1 to each copy
replicateInParallel :: Int -> (ThreadNum -> IO a) -> IO [a]
replicateInParallel par act = do
  ms <- mapM (runInThread . act) [0..par-1]
  mapM takeMVar ms

-- TODO: copied from fusebench.hs
data FsSystem = Fscq | Cfscq | Ext4
  deriving (Bounded, Enum)

instance Show FsSystem where
  show s = case s of
             Fscq -> "fscq"
             Cfscq -> "cfscq"
             Ext4 -> "ext4"

fsOption :: String -> DefineOptions FsSystem
fsOption flag = defineOption (optionType_enum "system") $ \o -> o
    { optionLongFlags=[flag]
    , optionDefault=Cfscq
    , optionDescription="file system to use (cfscq|fscq|ext4)" }

data ParOptions = ParOptions
  { optVerbose :: Bool
  , optShowDebug :: Bool
  , optSystem :: FsSystem
  , optDiskImg :: FilePath
  , optReps :: Int
  , optIters :: Int
  , optTargetMs :: Int
  , optN :: Int
  , optWarmup :: Bool }

instance Options ParOptions where
  defineOptions = pure ParOptions
    <*> simpleOption "verbose" False
        "print debug statements for parbench itself"
    <*> simpleOption "debug" False
        "print debug statements from (C)FSCQ"
    <*> fsOption "system"
    <*> simpleOption "img" "/tmp/disk.img"
         "path to FSCQ disk image"
    <*> simpleOption "reps" 1
         "number of repetitions to run per data point"
    <*> simpleOption "iters" 1
         "number of iterations to run"
    <*> simpleOption "target-ms" 0
         "pick iterations to run for at least this many ms (0 to disable)"
    <*> simpleOption "n" 1
         "number of parallel threads to use"
    <*> simpleOption "warmup" True
         "warmup by running untimed iterations"

-- fill in some dimensions based on global options
optsData :: ParOptions -> IO DataPoint
optsData ParOptions{..} = do
  rts <- getRtsInfo
  return $ emptyData{ pRts=rts
                    , pReps=optReps
                    , pWarmup=optWarmup
                    , pSystem=show optSystem
                    , pPar=optN }

logVerbose :: ParOptions -> String -> IO ()
logVerbose ParOptions{..} s = when optVerbose $ hPutStrLn stderr s

type Parcommand a = Subcommand ParOptions (IO a)

checkArgs :: [String] -> IO ()
checkArgs args = when (length args > 0) $ do
    putStrLn "arguments are unused, pass options as flags"
    exitWith (ExitFailure 1)

parcommand :: Options subcmdOpts =>
              String -> (ParOptions -> subcmdOpts -> IO a) ->
              Parcommand a
parcommand name action = subcommand name $ \opts cmdOpts args -> do
  checkArgs args
  action opts cmdOpts

type NumIters = Int

searchIters :: ParOptions -> (NumIters -> IO a) -> Double -> IO a
searchIters opts act targetMicros = go 1
  where go iters = do
          performMajorGC
          logVerbose opts $ "trying " ++ show iters ++ " iters"
          (x, micros) <- timed $ act iters
          if micros < targetMicros
            then let iters' = fromInteger . round $
                       (fromIntegral iters :: Double) * targetMicros / micros
                     nextIters = max
                       (min
                         (iters'+(iters' `div` 5))
                         (100*iters))
                       (iters+1) in
                 go nextIters
          else return x

pickAndRunIters :: ParOptions -> (NumIters -> IO a) -> IO a
pickAndRunIters opts@ParOptions{..} act = do
  if optTargetMs > 0 then
    searchIters opts act (fromIntegral optTargetMs * 1000)
  else act optIters

parallelTimeForIters :: Int -> (ThreadNum -> IO a) -> NumIters -> IO [Double]
parallelTimeForIters par act iters =
  concat <$> (replicateInParallel par $ \tid ->
    if tid == 0
    then replicateM iters (timeIt . act $ tid)
    else replicateM_ iters (act tid) >> return [])

parallelBench :: ParOptions -> IO b -> (b -> ThreadNum -> IO a) -> (b -> IO ()) -> IO [DataPoint]
parallelBench opts@ParOptions{..} prepare act cleanup = do
  setup <- prepare
  when optWarmup $ do
    forM_ [0..optN-1] (act setup)
    logVerbose opts "===> warmup done <==="
  performMajorGC
  micros <- pickAndRunIters opts $
    parallelTimeForIters optN $ replicateM_ optReps . (act setup)
  cleanup setup
  p <- optsData opts
  return $ map (\t -> p{ pIters=length micros
                       , pElapsedMicros=t }) micros

reportTimings :: ParOptions -> Filesystem fh -> IO ()
reportTimings ParOptions{..} fs = when optShowDebug $ do
  tm <- readIORef (timings fs)
  printTimings tm

withFs :: ParOptions -> (forall fh. Filesystem fh -> IO a) -> IO a
withFs opts@ParOptions{..} act =
  case optSystem of
    Fscq -> do
      fs <- initFscq optDiskImg True getProcessIds
      act fs <* reportTimings opts fs
    Cfscq -> do
      fs <- initCfscq optDiskImg True getProcessIds
      act fs <* reportTimings opts fs
    Ext4 -> withExt4 act

clearTimings :: Filesystem fh -> IO ()
clearTimings fs = writeIORef (timings fs) emptyTimings

benchCommand :: Options subcmdOpts =>
             String -> (forall fh.
                        ParOptions -> subcmdOpts -> Filesystem fh -> IO [DataPoint]) ->
             Parcommand ()
benchCommand name bench = parcommand name $ \opts cmdOpts -> do
  ps <- withFs opts $ \fs -> bench opts cmdOpts fs
  reportData $ map (\p -> p{pBenchName=name}) ps

benchmarkWithSetup :: Options subcmdOpts =>
                      String ->
                      (forall fh.
                       ParOptions -> subcmdOpts -> Filesystem fh -> IO b) ->
                      (forall fh.
                       ParOptions -> subcmdOpts -> Filesystem fh -> b -> ThreadNum -> IO a) ->
                      Parcommand ()
benchmarkWithSetup name prepare act = benchCommand name $ \opts cmdOpts fs ->
  parallelBench opts
    (clearTimings fs >> prepare opts cmdOpts fs)
    (\setup thread -> act opts cmdOpts fs setup thread)
    (\_ -> return ())

benchmarkWithInode :: Options subcmdOpts =>
                      String ->
                      (forall fh.
                       ParOptions -> subcmdOpts -> Filesystem fh -> IO fh) ->
                      (forall fh.
                       ParOptions -> subcmdOpts -> Filesystem fh -> fh -> ThreadNum -> IO a) ->
                      Parcommand ()
benchmarkWithInode name prepare act = benchCommand name $ \opts cmdOpts fs ->
  parallelBench opts
    (clearTimings fs >> prepare opts cmdOpts fs)
    (\setup thread -> act opts cmdOpts fs setup thread)
    (\inum -> closeFile (fuseOps fs) "(unknown)" inum)

simpleBenchmarkWithInode :: Options subcmdOpts =>
                      String ->
                      (forall fh.
                       ParOptions -> subcmdOpts -> Filesystem fh -> IO fh) ->
                      (forall fh.
                       ParOptions -> subcmdOpts -> Filesystem fh -> fh -> IO a) ->
                      Parcommand ()
simpleBenchmarkWithInode name prepare act =
  benchmarkWithInode name prepare (\opts cmdOpts fs inum _thread -> act opts cmdOpts fs inum)

simpleBenchmarkWithSetup :: Options subcmdOpts =>
                            String ->
                            (forall fh.
                             ParOptions -> subcmdOpts -> Filesystem fh -> IO b) ->
                            (forall fh.
                             ParOptions -> subcmdOpts -> Filesystem fh -> b -> IO a) ->
                            Parcommand ()
simpleBenchmarkWithSetup name prepare act =
  benchmarkWithSetup name prepare
  (\opts cmdOpts fs setup _thread -> act opts cmdOpts fs setup)

simpleBenchmark :: Options subcmdOpts =>
                   String -> (forall fh.
                              ParOptions -> subcmdOpts -> Filesystem fh -> IO a) ->
                   Parcommand ()
simpleBenchmark name act = simpleBenchmarkWithSetup name
  (\_ _ _ -> return ())
  (\opts cmdOpts fs _ -> act opts cmdOpts fs)

data IOConcurOptions =
  IOConcurOptions { optLargeFile :: String
                  , optSmallFile :: String }

instance Options IOConcurOptions where
  defineOptions = IOConcurOptions <$>
    simpleOption "large-file" "/large"
       "path to large file to read once"
    <*> simpleOption "small-file" "/small"
       "path to small file to read <reps> times"

parIOConcur :: Int -> IOConcurOptions -> Filesystem fh -> IO (Double, Double)
parIOConcur reps IOConcurOptions{..} fs = do
  m1 <- timeAsync $ readEntireFile fs Nothing optLargeFile
  size <- getFileSize (fuseOps fs) optSmallFile
  m2 <- timeAsync $ replicateM_ reps (readEntireFile fs (Just size) optSmallFile)
  largeMicros <- takeMVar m1
  smallMicros <- takeMVar m2
  return (largeMicros, smallMicros)

seqIOConcur :: Int -> IOConcurOptions -> Filesystem fh -> IO (Double, Double)
seqIOConcur reps IOConcurOptions{..} fs = do
  largeMicros <- timeIt $ readEntireFile fs Nothing optLargeFile
  size <- getFileSize (fuseOps fs) optSmallFile
  smallMicros <- timeIt $ replicateM_ reps (readEntireFile fs (Just size) optSmallFile)
  return (largeMicros, smallMicros)

runIOConcur :: ParOptions -> IOConcurOptions -> Filesystem fh -> IO [DataPoint]
runIOConcur opts@ParOptions{..} ioOpts fs = do
  (largeMicros, smallMicros) <-
    if optN >= 2
    then parIOConcur optReps ioOpts fs
    else seqIOConcur optReps ioOpts fs
  basePoint <- optsData opts
  let p = basePoint{ pIters=1
                   , pWarmup=False } in
    return $ [ p{ pBenchCategory="large"
                , pReps=1
                , pElapsedMicros=largeMicros }
              , p{ pBenchCategory="small"
                 , pReps=optReps
                 , pElapsedMicros=smallMicros} ]

ioConcurCommand :: Parcommand ()
ioConcurCommand = benchCommand "io-concur" $ \opts cmdOpts fs ->
  runIOConcur opts cmdOpts fs

data ParallelSearchOptions =
  ParallelSearchOptions { searchDir :: FilePath
                        , searchString :: String }

instance Options ParallelSearchOptions where
  defineOptions = pure ParallelSearchOptions
    <*> simpleOption "dir" "/search-benchmarks/coq"
        "directory to search under"
    <*> simpleOption "query" "propositional equality"
        "string to search for"

withCapabilities :: Int -> IO a -> IO a
withCapabilities n act = do
  n' <- getNumCapabilities
  setNumCapabilities n
  r <- act
  setNumCapabilities n'
  return r

parSearch :: ParallelSearchOptions -> Filesystem fh -> Int -> IO [(FilePath, Int)]
parSearch ParallelSearchOptions{..} Filesystem{fuseOps} par =
  parallelSearchAtRoot fuseOps par (BSC8.pack searchString) searchDir

printSearchResults :: ParOptions -> [(FilePath, Int)] -> IO ()
printSearchResults opts = mapM_ $ \(p, count) -> do
  when (count > 0) $ logVerbose opts $ p ++ ": " ++ show count

runParallelSearch :: ParOptions -> ParallelSearchOptions -> Filesystem fh -> IO [DataPoint]
runParallelSearch opts@ParOptions{..} cmdOpts fs = do
  let benchmark = parSearch cmdOpts fs
  when optWarmup $ do
    _ <- withCapabilities 1 $ benchmark optN
    clearTimings fs
    logVerbose opts "===> warmup done <==="
  performMajorGC
  micros <- pickAndRunIters opts $ \iters ->
    replicateM iters . timeIt $ replicateM_ optReps $ do
      results <- benchmark optN
      when optVerbose $ printSearchResults opts results
  p <- optsData opts
  return $ map (\t -> p{pElapsedMicros=t}) micros

parSearchCommand :: Parcommand ()
parSearchCommand = benchCommand "par-search" $ \opts cmdOpts fs ->
  runParallelSearch opts cmdOpts fs

data DbenchOptions =
  DbenchOptions { rootDir :: FilePath
                , scriptFile :: FilePath }

instance Options DbenchOptions where
  defineOptions = pure DbenchOptions
    <*> simpleOption "dir" "/dbench"
        "directory to run dbench script under"
    <*> simpleOption "script" "client.txt"
        "path to dbench fileio script to run (client.txt)"

runDbenchScript :: ParOptions -> DbenchOptions -> Filesystem fh -> IO [DataPoint]
runDbenchScript opts@ParOptions{..} DbenchOptions{..} Filesystem{fuseOps} = do
  parse <- parseScriptFile scriptFile
  case parse of
    Left e -> error e
    Right script -> do
    -- TODO: potentially need to force script
    logVerbose opts $ intercalate "\n" (map show script)
    performMajorGC
    let threadRoot tid = rootDir ++ "/core" ++ show tid
        run tid = runScript fuseOps . prefixScript (threadRoot tid) $ script in do
    micros <- parallelTimeForIters optN run optIters
    p <- optsData opts
    return $ map (\t -> p
                   { pWarmup=False
                   , pReps=1
                   , pElapsedMicros=t }) micros

dbenchCommand :: Parcommand ()
dbenchCommand = benchCommand "dbench" $ \opts cmdOpts fs ->
  runDbenchScript opts cmdOpts fs

headerCommand :: Parcommand ()
headerCommand = parcommand "print-header" $ \_ (_::NoOptions) -> do
  putStrLn . dataHeader . dataValues $ emptyData

type UniqueCtr = [IORef Int]

initUnique :: Int -> IO UniqueCtr
initUnique par = replicateM par (newIORef 0)

getUnique :: UniqueCtr -> ThreadNum -> IO Int
getUnique ctr t = let ref = ctr !! t in do
  c <- readIORef ref
  modifyIORef' ref (+1)
  return c

data WriteOptions =
  WriteOptions { writeDir :: FilePath }

instance Options WriteOptions where
  defineOptions = pure WriteOptions
    <*> simpleOption "dir" "/empty-dir"
        "directory to write within"

counterPrepare :: ParOptions -> subcmdOpts -> Filesystem fh -> IO UniqueCtr
counterPrepare ParOptions{..} _ _ = initUnique optN

uniqueName :: ThreadNum -> Int -> String
uniqueName tid n = "thread" ++ show tid ++ "_file" ++ show n

genericCounterOp :: (String -> IO a) -> UniqueCtr -> ThreadNum -> IO ()
genericCounterOp act ctr tid = do
  n <- getUnique ctr tid
  _ <- act (uniqueName tid n)
  return ()

createOp :: ParOptions -> WriteOptions -> Filesystem fh ->
            UniqueCtr -> ThreadNum -> IO ()
createOp _ WriteOptions{..} Filesystem{fuseOps} = genericCounterOp $ \name -> do
  let fname = writeDir ++ "/" ++ name
  inum <- getResult fname =<< fuseCreateFile fuseOps fname ownerModes ReadWrite defaultFileFlags
  closeFile fuseOps fname inum
  return ()

createDirOp :: ParOptions -> WriteOptions -> Filesystem fh ->
               UniqueCtr -> ThreadNum -> IO ()
createDirOp _ WriteOptions{..} Filesystem{fuseOps} = genericCounterOp $ \name -> do
  let fname = writeDir ++ "/" ++ name
  checkError fname $ fuseCreateDirectory fuseOps fname ownerModes

writeFilePrepare :: forall fh. ParOptions -> WriteOptions -> Filesystem fh ->
                    IO [(FilePath, fh)]
writeFilePrepare ParOptions{..} WriteOptions{..} fs = do
  forM [0..optN-1] $ \tid -> do
    let fname = uniqueName tid 0
    -- TODO: this file needs to be closed when the benchmark is done
    inum <- createSmallFile fs fname
    return (fname, inum)

writeFileOp :: forall fh. ParOptions -> WriteOptions -> Filesystem fh ->
               [(FilePath, fh)] -> ThreadNum -> IO ()
writeFileOp _ WriteOptions{..} Filesystem{fuseOps=fs} inums tid = do
  let (fname, inum) = inums !! tid
  bytes <- getResult fname =<< fuseWrite fs fname inum zeroBlock 0
  when (bytes < 4096) (error $ "failed to write to " ++ fname)
  return ()

data ReaderWriterOptions = ReaderWriterOptions
  { optRWSmallFile :: FilePath
  , optRWWriteDir :: FilePath
  , optWriteReps :: Int
  , optOnlyReads :: Bool }

instance Options ReaderWriterOptions where
  defineOptions = pure ReaderWriterOptions
    <*> simpleOption "file" "/small"
        "small file to read"
    <*> simpleOption "dir" "/empty-dir"
        "directory to write to"
    <*> simpleOption "write-reps" 1
        "run this many reps for writes (reps applies to reads)"
    <*> simpleOption "only-reads" False
        "skip writes altogether"

rwRead :: ParOptions -> ReaderWriterOptions -> Filesystem fh -> IO ()
rwRead ParOptions{..} ReaderWriterOptions{..} fs =
  replicateM_ optReps $ readEntireFile fs Nothing optRWSmallFile

rwWrite :: ParOptions -> ReaderWriterOptions -> Filesystem fh ->
           UniqueCtr -> ThreadNum -> IO ()
rwWrite ParOptions{..} ReaderWriterOptions{..} fs ctr tid =
  replicateM_ optWriteReps $ genericCounterOp (\name ->
  let fname = optRWWriteDir ++ "/" ++ name in
    createSmallFile fs fname) ctr tid

data TerminateThreadException = TerminateThreadException
  deriving Show

instance Exception TerminateThreadException

runTillException :: IO a -> IO [a]
runTillException act = do
  mx <- catch (Just <$> act) (\(_::TerminateThreadException) -> return Nothing)
  case mx of
    Nothing -> return []
    Just x -> (x:) <$> runTillException act

repeatTillTerminated :: IO a -> IO (ThreadId, MVar [a])
repeatTillTerminated act = do
  m_result <- newEmptyMVar
  tid <- forkIO $ do
    v <- runTillException act
    putMVar m_result v
  return (tid, m_result)

terminateThread :: (ThreadId, MVar a) -> IO a
terminateThread (tid, m_result) = do
  throwTo tid TerminateThreadException
  takeMVar m_result


data RawReadWriteResults = RawReadWriteResults
  { readTimings :: [Double]
  , writeTimings :: [Double] }

runInThreads :: Int -> NumIters -> IO a -> IO (MVar [a])
runInThreads par iters act = runInThread $ do
  m_results <- runInThread $ replicateM iters act
  other_results <- replicateM (par-1) $ runInThread act
  forM_ other_results takeMVar
  takeMVar m_results

readwriteIterate :: ParOptions -> ReaderWriterOptions -> Filesystem fh ->
                    UniqueCtr -> NumIters -> IO RawReadWriteResults
readwriteIterate opts@ParOptions{..} cmdOpts fs ctr iters =
  let readOp = rwRead opts cmdOpts fs
      writeOp = rwWrite opts cmdOpts fs ctr 0 in
    if optOnlyReads cmdOpts then do
        m_reads <- runInThreads optN iters $ timeIt readOp
        readTimes <- takeMVar m_reads
        return $ RawReadWriteResults { readTimings=readTimes
                                     , writeTimings=[]}
    else
      if optN == 0 then do
        writeTimes <- replicateM iters $ timeIt writeOp
        return $ RawReadWriteResults { readTimings=[]
                                     , writeTimings=writeTimes}
      else do
        m_reads <- runInThreads optN iters $ timeIt readOp
        write_thread <- repeatTillTerminated $ timeIt writeOp
        readTimes <- takeMVar m_reads
        writeTimes <- terminateThread write_thread
        return $ RawReadWriteResults { readTimings=readTimes
                                     , writeTimings=writeTimes }

readWriteData :: ParOptions -> ReaderWriterOptions -> RawReadWriteResults -> IO [DataPoint]
readWriteData opts@ParOptions{..} ReaderWriterOptions{..} RawReadWriteResults{..} = do
  p <- optsData opts
  let for = flip map
      readPoints = for readTimings $ \f ->
        p { pBenchCategory="reader"
          , pElapsedMicros=f
          , pIters=length readTimings }
      writePoints = for writeTimings $ \f ->
        p { pBenchCategory="writer"
          , pElapsedMicros=f
          , pReps=optWriteReps
          , pIters=length writeTimings }
  return (readPoints ++ writePoints)

warmupReadWrite :: ParOptions ->
                   IO a -> (UniqueCtr -> ThreadNum -> IO b) ->
                   IO UniqueCtr
warmupReadWrite opts@ParOptions{..} readOp writeOp = do
  -- sometimes we have a writer thread but no readers
  ctr <- initUnique (max 1 optN)
  when optWarmup $ do
    _ <- readOp
    _ <- writeOp ctr 0
    logVerbose opts "===> warmup done <==="
  return ctr

runReadersWriter :: ParOptions -> ReaderWriterOptions -> Filesystem fh ->
                    IO [DataPoint]
runReadersWriter opts cmdOpts fs = do
  ctr <- warmupReadWrite opts (rwRead opts cmdOpts fs) (rwWrite opts cmdOpts fs)
  performMajorGC
  raw <- pickAndRunIters opts $
    readwriteIterate opts cmdOpts fs ctr
  ps <- readWriteData opts cmdOpts raw
  return ps

readwriteCommand :: Parcommand ()
readwriteCommand = benchCommand "readers-writer" $ \opts cmdOpts fs -> do
  runReadersWriter opts cmdOpts fs

data RawReadWriteMixResults = RawReadWriteMixResults
  { -- (isRead, micros) tuples
    readWriteMixTimings :: [(Bool, Double)] }

randomDecisions :: RandomGen g =>
                   Double -> g -> [Bool]
randomDecisions percTrue gen = do
  map (\f -> f < percTrue) (randomRs (0.0, 1.0) gen)

randomReadWrites :: RandomGen g =>
                    Double ->
                    g -> NumIters ->
                    -- read and write ops
                    IO a -> IO b ->
                    IO RawReadWriteMixResults
randomReadWrites readPerc gen iters readOp writeOp =
  let isReads = take iters $ randomDecisions readPerc gen in do
  timings <- forM isReads $ \isRead -> do
    t <- if isRead then timeIt $ readOp else timeIt $ writeOp
    return (isRead, t)
  return $ RawReadWriteMixResults timings

parRandomReadWrites :: ParOptions -> Double ->
                       IO a -> (ThreadNum -> IO b) ->
                       NumIters ->
                       IO RawReadWriteMixResults
parRandomReadWrites ParOptions{..} readPerc readOp writeOp iters = do
  gens <- replicateM optN newStdGen
  m_results <- forM (zip [0..] gens) $ \(tid, gen) ->
    runInThread $ randomReadWrites readPerc gen iters readOp (writeOp tid)
  threadResults <- mapM takeMVar m_results
  -- TODO: should we report results from every thread?
  return $ head threadResults

data ReadWriteMixOptions = ReadWriteMixOptions
  { optMixReaderWriter :: ReaderWriterOptions
  , optMixReadPercentage :: Double }

instance Options ReadWriteMixOptions where
  defineOptions = pure ReadWriteMixOptions
    <*> defineOptions
    <*> simpleOption "read-perc" 0.5
        "percentage of reads to issue"

rwMixData :: ParOptions -> ReaderWriterOptions -> RawReadWriteMixResults -> IO [DataPoint]
rwMixData opts@ParOptions{..} ReaderWriterOptions{..} RawReadWriteMixResults{..} = do
  p <- optsData opts
  let for = flip map
      ps = for readWriteMixTimings $ \(isRead, f) ->
        p { pBenchCategory=if isRead then "r" else "w"
          , pReps=if isRead then optReps else optWriteReps
          , pElapsedMicros=f
          , pIters=length readWriteMixTimings }
  return ps

runReadWriteMix :: ParOptions -> ReadWriteMixOptions -> Filesystem fh ->
                   IO [DataPoint]
runReadWriteMix opts ReadWriteMixOptions{..} fs = do
  let readOp = rwRead opts optMixReaderWriter fs
      writeOp = rwWrite opts optMixReaderWriter fs
  ctr <- warmupReadWrite opts readOp writeOp
  performMajorGC
  raw <- pickAndRunIters opts $
    parRandomReadWrites opts optMixReadPercentage readOp (writeOp ctr)
  ps <- rwMixData opts optMixReaderWriter raw
  return ps

readWriteMixCommand :: Parcommand ()
readWriteMixCommand = benchCommand "rw-mix" $ \opts cmdOpts fs ->
  runReadWriteMix opts cmdOpts fs

data MailServerOptions = MailServerOptions
  { optMailConfig :: Config
  , optMailNumUsers :: Int
  , optMailInitialMessages :: Int }

instance Options MailServerOptions where
  defineOptions = pure MailServerOptions
    <*> defineOptions
    <*> simpleOption "users" 1
        "number of user threads to create"
    <*> simpleOption "init-messages" 0
        "number of messages to initialize before workload"

runMailServer :: ParOptions -> MailServerOptions -> Filesystem fh ->
                 IO [DataPoint]
runMailServer opts MailServerOptions{..} fs = do
  initializeMailboxes optMailConfig fs optMailNumUsers optMailInitialMessages
  t <- timeIt $ runInParallel optMailNumUsers $
    randomOps optMailConfig fs (optReps opts)
  cleanupMailboxes optMailConfig fs
  p <- optsData opts
  return $ [ p{ pElapsedMicros=t
              , pWarmup=True -- TODO: should support disabling this
              , pIters=1 } ]

mailServerCommand :: Parcommand ()
mailServerCommand = benchCommand "mailserver" $ \opts cmdOpts fs ->
  runMailServer opts cmdOpts fs

main :: IO ()
main = do
  setStdGen (mkStdGen 0)
  runSubcommand [ simpleBenchmark "stat" statOp
                , simpleBenchmark "open" openOp
                , simpleBenchmark "statfs" statfsOp
                , simpleBenchmark "cat-dir" catDirOp
                , simpleBenchmark "cat-file" catFileOp
                , simpleBenchmarkWithInode "readdir" readDirPrepare readDirOp
                , simpleBenchmarkWithInode "read" readFilePrepare readFileOp
                , simpleBenchmark "traverse-dir" traverseDirOp
                , benchmarkWithSetup "create" counterPrepare createOp
                , benchmarkWithSetup "create-dir" counterPrepare createDirOp
                -- this is just benchmarkWithSetup inlined - somehow it doesn't
                -- have the most general type?
                , benchCommand "write" $ \opts cmdOpts fs ->
                    parallelBench opts
                    (clearTimings fs >> writeFilePrepare opts cmdOpts fs)
                    (\setup thread -> writeFileOp opts cmdOpts fs setup thread)
                    (\files -> mapM_ (closeFile (fuseOps fs) "(unknown)" . snd) files)
                , ioConcurCommand
                , parSearchCommand
                , dbenchCommand
                , readwriteCommand
                , readWriteMixCommand
                , mailServerCommand
                , headerCommand ]