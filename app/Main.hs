{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE BangPatterns #-}

module Main where

import           Parameters
import qualified Parameters.Weights as Weights
import qualified Parameters.Tree as Tree
import qualified Parameters.Requests as Requests
import qualified Parameters.Algorithm as Alg

import           Evaluation
import           Evaluation.Tree
import Evaluation.Utils
import Evaluation.Request

import           Polysemy
import           Polysemy.RandomFu
import           Polysemy.Trace
import           Control.Monad
import           System.IO
import           Prelude hiding ((.), id)
import Pipes
import qualified Pipes.Prelude as P
import Arvy.Local
import Polysemy.Reader
import Data.Array.MArray
import System.Directory
import System.FilePath

main :: IO ()
main = runM $ runTraceIO
  initialTreeMatters

createHandle :: FilePath -> IO Handle
createHandle path = do
  createDirectoryIfMissing True (takeDirectory path)
  liftIO $ putStrLn $ "Opening handle to " ++ path
  openFile path WriteMode


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
      [ Weights.ring
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
  eval :: (MArray arr Node IO, Members '[Reader (Env arr), Lift IO] r) => (Handle, Handle) -> Int -> GraphWeights -> Consumer ArvyEvent (Sem r) ()
  eval (stretchHandle, ratioHandle) n w = ratio w
    >-> Evaluation.Utils.enumerate
    >-> distribute
    [ decayingFilter 4
      >-> treeStretchDiameter n w
      >-> P.map (\((i, _), (stretch, _)) -> show i ++ " " ++ show stretch)
      >-> P.toHandle stretchHandle
    , P.map (\(i, rat) -> show i ++ " " ++ show rat)
      >-> P.toHandle ratioHandle
    , everyNth 1000
      >-> P.map (\(i, _) -> show i)
      >-> P.stdoutLn
    ]

toFile :: MonadIO m => FilePath -> Consumer String m ()
toFile path = do
  liftIO $ createDirectoryIfMissing True (takeDirectory path)
  liftIO $ putStrLn $ "Writing to " ++path
  handle <- liftIO $ openFile path WriteMode
  () <- P.toHandle handle
  liftIO $ hClose handle
