module ParametersLibrary where

import           Arvy.Requests
import           Arvy.Weights
import Arvy.Tree
import           Parameters
import Polysemy
import Polysemy.RandomFu
import Data.Array

pWorstRequests :: RequestsParameter r
pWorstRequests = RequestsParameter
  { requestsName = "worst"
  , requestsGet = get
  } where
  get :: Int -> GraphWeights -> Array Int (Maybe Int) -> Sem r Int
  get _ weights tree = return $ worstRequest weights tree


pRandomRequests :: Member RandomFu r => RequestsParameter r
pRandomRequests = RequestsParameter
  { requestsName = "random"
  , requestsGet = get
  } where
  get :: Member RandomFu r => Int -> GraphWeights -> Array Int (Maybe Int) -> Sem r Int
  get n _ _ = randomRequest n

pInteractiveRequests :: Member (Lift IO) r => RequestsParameter r
pInteractiveRequests = RequestsParameter
  { requestsName = "interactive"
  , requestsGet = \_ _ -> interactiveRequests
  }

pRingWeights :: WeightsParameter r
pRingWeights = WeightsParameter "ring" (return . ringWeights)

pMst :: InitialTreeParameter r
pMst = InitialTreeParameter "mst" (\n w -> return (mst n w))

pRing :: InitialTreeParameter r
pRing = InitialTreeParameter "ring" (\n _ -> return (ringTree n))

pSemiCircles :: InitialTreeParameter r
pSemiCircles = InitialTreeParameter "semi circles" (\n _ -> return (semiCircles n))

pBarabasiWeights :: Member RandomFu r => Int -> WeightsParameter r
pBarabasiWeights m = WeightsParameter
  { weightsName = "Barabasi Albert"
  , weightsGet = (`barabasiAlbert` m)
  }
  
pErdosRenyi :: Member (Lift IO) r => WeightsParameter r
pErdosRenyi = WeightsParameter
  { weightsName = "Erdos Renyi"
  , weightsGet = \n -> do
      -- According to Erdos and Renyi, a graph is very likely to be connected with p > (1 + e) ln n / n
      let p = log (fromIntegral n) / fromIntegral n
      erdosRenyi n p
  }

