{-# LANGUAGE BangPatterns #-}

module Main where

import           Parameters
import qualified Parameters.Weights as Weights
import qualified Parameters.Tree as Tree
import qualified Parameters.Requests as Requests
import qualified Parameters.Algorithm as Alg

import Evaluation

import           Polysemy
import           Polysemy.RandomFu
import           Polysemy.Trace
import           Control.Monad
import           System.IO
import           Prelude hiding ((.), id)
import Pipes hiding (enumerate)
import qualified Pipes.Prelude as P
import Arvy.Local
import Data.Array.IO
import System.Directory
import Data.Ratio
import System.FilePath

main :: IO ()
main = runM $ runTraceIO
  --initialTreeMatters
  inbetweenParameter
  --testing

inbetweenParameter :: Members '[Lift IO, Trace] r => Sem r ()
inbetweenParameter = forM_ params $ \par -> do
  let ratioPath = "inbetweenParameter" </> paramFile par "ratio"
  ratioHandle <- liftIO $ createHandle ratioPath
  runParams par
    $ eval ratioHandle
  liftIO $ hClose ratioHandle

  where

  params :: Members '[RandomFu, Lift IO, Trace] r => [Parameters r]
  params =
    [ Parameters
      { randomSeed = 0
      , nodeCount = 2000
      , requestCount = 100000
      , weights = weights
      , requests = reqs
      , algorithm = alg
      }
    | weights <-
      [ Weights.unitEuclidian 10
      ]
    , alg <-
      [ Alg.arrow
      , Alg.inbetween (1 % 2) Tree.mst
      , Alg.inbetween (1 % 4) Tree.mst
      , Alg.inbetween (1 % 6) Tree.mst
      , Alg.inbetween (1 % 8) Tree.mst
      , Alg.ivy Tree.mst
      , Alg.random Tree.mst
      ]
    , reqs <-
      [ --Requests.random
       Requests.pareto
      ]
    ]
  eval :: Member (Lift IO) r => Handle -> Int -> GraphWeights -> IOUArray Node Node -> Consumer ArvyEvent (Sem r) ()
  eval ratioHandle n w t = ratio w
    >-> distribute
    [ movingAverage True 250
      >-> enumerate
      >-> decayingFilter 10
      >-> P.map (\(i, rat) -> show i ++ " " ++ show rat)
      >-> P.toHandle ratioHandle
    , enumerate
      >-> everyNth 2000
      >-> P.map (\(i, _) -> show i)
      >-> P.stdoutLn
    ] where

createHandle :: FilePath -> IO Handle
createHandle path = do
  createDirectoryIfMissing True (takeDirectory path)
  liftIO $ putStrLn $ "Opening handle to " ++ path
  openFile path WriteMode

testing :: Members '[Lift IO, Trace] r => Sem r ()
testing = runParams Parameters
  { randomSeed = 0
  , nodeCount = 20
  , requestCount = 10
  , weights = Weights.erdosRenyi (Weights.ErdosProbEpsilon 0)
  , requests = Requests.interactive
  , algorithm = Alg.inbetween (1 % 2) Tree.random
  } \n w t -> P.show >-> P.stdoutLn

initialTreeMatters :: Members '[Lift IO, Trace] r => Sem r ()
initialTreeMatters = forM_ params $ \par -> do
  let stretchPath = "initialTreeMatters" </> paramFile par "stretch"
  stretchHandle <- liftIO $ createHandle stretchPath
  let ratioPath = "initialTreeMatters" </> paramFile par "ratio"
  ratioHandle <- liftIO $ createHandle ratioPath
  runParams par
    $ eval (stretchHandle, ratioHandle)
  liftIO $ hClose stretchHandle
  liftIO $ hClose ratioHandle

  where

  params :: Members '[RandomFu, Lift IO, Trace] r => [Parameters r]
  params =
    [ Parameters
      { randomSeed = 0
      , nodeCount = 1000
      , requestCount = 100000
      , weights = weights
      , requests = reqs
      , algorithm = alg
      }
    | weights <-
      [ Weights.erdosRenyi (Weights.ErdosProbEpsilon 0)
      , Weights.ring
      ]
    , tree <-
      [ Tree.random
      , Tree.mst
      ]
    , alg <- ($ tree) <$>
      [ Alg.ivy
      , Alg.half
      ]
    , reqs <-
      [ Requests.random
      ]
    ]
  eval :: Member (Lift IO) r => (Handle, Handle) -> Int -> GraphWeights -> IOUArray Node Node -> Consumer ArvyEvent (Sem r) ()
  eval (stretchHandle, ratioHandle) n w t = ratio w
    >-> distribute
    [ enumerate
      >-> decayingFilter 4
      >-> treeStretchDiameter n w t
      >-> P.map (\((i, _), (stretch, _)) -> show i ++ " " ++ show stretch)
      >-> P.toHandle stretchHandle
    , movingAverage True 100
      >-> enumerate
      >-> decayingFilter 10
      >-> P.map (\(i, rat) -> show i ++ " " ++ show rat)
      >-> P.toHandle ratioHandle
    , enumerate
      >-> decayingFilter 10
      >-> P.map (\(i, _) -> show i)
      >-> P.stdoutLn
    ] where

toFile :: MonadIO m => FilePath -> Consumer String m ()
toFile path = do
  liftIO $ createDirectoryIfMissing True (takeDirectory path)
  liftIO $ putStrLn $ "Writing to " ++path
  handle <- liftIO $ openFile path WriteMode
  () <- P.toHandle handle
  liftIO $ hClose handle
