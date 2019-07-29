{-# LANGUAGE BlockArguments #-}

module Parameters.Weights
  ( WeightsParameter(..)
  , ring
  , clique
  , unitEuclidian
  , barabasiAlbert
  , ErdosProb(..)
  , erdosRenyi
  , shortestPathWeights
  ) where

import Arvy.Local
import Utils

import Polysemy
import Polysemy.RandomFu
import Polysemy.Trace
import qualified Algebra.Graph.Class as G
import qualified Algebra.Graph.AdjacencyIntMap as GA
import Data.Array.IArray (elems)
import Control.Monad
import Data.List (foldl')
import Data.IntSet (IntSet)
import qualified Data.IntSet as IntSet
import Data.IntMultiSet (IntMultiSet)
import qualified Data.IntMultiSet as IntMultiSet
import Data.Random.Distribution.Uniform
import Data.Array.MArray
import Data.Array.ST
import Data.Array.Unboxed
import qualified Data.Array as A

-- TODO: Differentiate between graphs that have an underlying graph and ones that don't
-- | A type for generating certain complete graph weights with access to effects in @r@
data WeightsParameter r = WeightsParameter
  { weightsId :: String
  -- ^ The identifying string for this type of weights
  , weightsDescription :: String
  -- ^ The description of how these weights are generated
  , weightsGet  :: NodeCount -> Sem r GraphWeights
  -- ^ Generate weights for a certain number of nodes
  }

-- TODO: Does this really not use any additional storage?
-- | Generate weights for all vertex pairs from an underlying incomplete graph by calculating the shortest path between them. The Floyd-Warshall algorithm is used to compute this, so complexity is /O(m + n^3)/ with n being the number of vertices and m being the number of edges, no additional space except the resulting weights itself is used. Edge weights in the underlying graph are always assumed to be 1. Use 'symmetricClosure' on the argument to force an undirected graph.
shortestPathWeights :: NodeCount -> GA.AdjacencyIntMap -> GraphWeights
shortestPathWeights n graph = runSTUArray $ do
  -- Initialize array with all edges being infinity, representing no paths between any nodes
  weights <- newArray ((0, 0), (n - 1, n - 1)) infinity

  -- Set all known edges to weight 1
  forM_ (GA.edgeList graph) $ \edge ->
    writeArray weights edge 1

  -- Set all weights from nodes to themselves to 0
  forM_ (GA.vertexList graph) $ \x ->
    -- Catch invalid indices early. Could also implement automatix shifting down of
    -- indices to fill all holes, but this shouldn't happen anyways for normal usage
    if x >= n
    then error $ "shortestPathWeights: Graph has vertex with index " ++ show x
      ++ " which is above or equal the number of total vertices " ++ show n
      ++ ". Some vertex index under that is not present in the graph"
      ++ ", shift all node indices down to fill the range."
    else writeArray weights (x, x) 0

  -- Compute shortest paths
  floydWarshall n weights

  return weights

ring :: WeightsParameter r
ring = WeightsParameter
  { weightsId = "ring"
  , weightsDescription = "All nodes are connected in a circle with weight 1"
  , weightsGet = \n ->
      return $ shortestPathWeights n $ GA.symmetricClosure $ GA.circuit [0..n-1]
  }

clique :: WeightsParameter r
clique = WeightsParameter
  { weightsId = "clique"
  , weightsDescription = "Clique, all nodes are connected with weight 1 to all other nodes"
  , weightsGet = \n ->
      return $ array ((0, 0), (n - 1, n - 1))
        [ ((i, j), weight)
        | i <- [0 .. n - 1]
        , j <- [0 .. n - 1]
        , let weight = if i == j then 0 else 1
        ]
  }

unitEuclidian :: Member RandomFu r => Int -> WeightsParameter r
unitEuclidian dim = WeightsParameter
  { weightsId = "uniform" ++ show dim
  , weightsDescription = "Euclidian distances for uniformly random points in a " ++ show dim ++ "-dimensional unit-hypercube"
  , weightsGet = \n -> do
      points <- A.listArray (0, n - 1) <$> replicateM n randomPoint
      return $ array ((0, 0), (n - 1, n - 1))
        [ ((u, v), distance (points ! u) (points ! v))
        | u <- [0 .. n - 1]
        , v <- [0 .. n - 1]
        ]
  } where
  -- | Selects a uniformly distributed random point in a multi-dimensional unit-hypercube
  randomPoint :: Member RandomFu r => Sem r (UArray Int Double)
  randomPoint = listArray (0, dim - 1) <$> replicateM dim (sampleRVar doubleStdUniform)

  -- | Multi-dimensional L2-distance
  distance :: UArray Int Double -> UArray Int Double -> Double
  distance x y = sqrt $ sum
    [ (x ! d - y ! d) ** 2
    | d <- [0 .. dim - 1] ]


data ErdosProb
  = ErdosProbEpsilon Double
  -- ^ An epsilon value for the formula (1 + e) * ln n / n

-- | Extract the probability from an 'ErdosProb' for the given number of edges
erdosProb :: ErdosProb -> Int -> Double
erdosProb (ErdosProbEpsilon e) n = (1 + e) * log (fromIntegral n) / fromIntegral n

erdosRenyi :: Members '[RandomFu, Trace] r => ErdosProb -> WeightsParameter r
erdosRenyi prob@(ErdosProbEpsilon e) = WeightsParameter
  { weightsId = "erdos" ++ show e
  , weightsDescription = "Erdos Renyi G(n, p) graph, where every edge has probability p = (1 + " ++ show e ++ ") * ln n / n of existing"
  , weightsGet = \n -> generate (erdosProb prob n) n
  } where

  generate :: Members '[RandomFu, Trace] r => Double -> Int -> Sem r GraphWeights
  generate p n = do
    -- Generate the random edges from lower to higher node indices only
    edges <- forM [ (u, v) | u <- [0 .. n - 1], v <- [u + 1 .. n - 1]] $ \edge -> do
      value <- sampleRVar doubleStdUniform
      return [ edge | value < p ]

    -- Make all edges bidirectional
    let graph = GA.symmetricClosure (GA.edges (concat edges))
    -- Calculate the weights with from the shortest paths
    let weights = shortestPathWeights n graph
    -- The graph is only connected when there exists a shortest paths between all nodes, which above function indicates with no infinity values
    if all (not . isInfinite) (elems weights)
      then return weights
      else do
        -- Try again if not connected
        trace $ "Erdos Renyi graph wasn't connected with edge probability p=" ++ show p ++ " and node count n=" ++ show n ++ " retrying.."
        generate p n


barabasiAlbert :: Member RandomFu r => Int -> WeightsParameter r
barabasiAlbert m = WeightsParameter
  { weightsId = "barabasi" ++ show m
  , weightsDescription = "Barabasi Albert scale-free network random graph with m = " ++ show m
  , weightsGet = \n -> do
      graph <- barabasiAlbertGen n m
      return $ shortestPathWeights n $ GA.symmetricClosure graph
  }

-- Adapted for algebraic-graphs and polysemy from graph-generators package
-- TODO: Is this correct? The code is very hard to follow
barabasiAlbertGen :: forall r g . (Member RandomFu r, G.Graph g, G.Vertex g ~ Node) => NodeCount -> Int -> Sem r g
barabasiAlbertGen n m = do
  -- Implementation concept: Iterate over nodes [m..n] in a state monad,
  --   building up the edge list
    -- (Our state: repeated nodes, current targets, edges)
  let initState = (IntMultiSet.empty, [0..m-1], G.vertices [0 .. m - 1])
  -- Strategy: Fold over the list, using a BarabasiState als fold state
  let folder :: (IntMultiSet, [Int], g) -> Int -> Sem r (IntMultiSet, [Int], g)
      folder st curNode = do
          let (repeatedNodes, targets, graph) = st
          -- Create new edges (for the current node)
          let newEdges = map (\t -> (curNode, t)) targets
          -- Add nodes to the repeated nodes multiset
          let newRepeatedNodes = foldl' (flip IntMultiSet.insert) repeatedNodes targets
          let newRepeatedNodes' = IntMultiSet.insertMany curNode m newRepeatedNodes
          -- Select the new target set randomly from the repeated nodes
          let repeatedNodesWithSize = (newRepeatedNodes, IntMultiSet.size newRepeatedNodes)
          newTargets <- selectNDistinctRandomElements m repeatedNodesWithSize
          return (newRepeatedNodes', newTargets, graph `G.overlay` G.edges newEdges)
  -- From the final state, we only require the edge list
  (_, _, allEdges) <- foldM folder initState [m..n-1]
  return allEdges

-- | Select the nth element from a multiset occur list, treating it as virtual large list
--   This is significantly faster than building up the entire list and selecting the nth
--   element
selectNth :: Int -> [(Int, Int)] -> Int
selectNth n [] = error $ "Can't select nth element - n is greater than list size (n=" ++ show n ++ ", list empty)"
selectNth n ((a,c):xs)
    | n <= c = a
    | otherwise = selectNth (n-c) xs

-- | Select a single random element from the multiset, with precalculated size
--   Note that the given size must be the total multiset size, not the number of
--   distinct elements in said se
selectRandomElement :: Member RandomFu r => (IntMultiSet, Int) -> Sem r Int
selectRandomElement (ms, msSize) = do
    let msOccurList = IntMultiSet.toOccurList ms
    r <- sampleRVar (integralUniform 0 (msSize - 1))
    return $ selectNth r msOccurList

-- | Select n distinct random elements from a multiset, with
--   This function will fail to terminate if there are less than n distinct
--   elements in the multiset. This function accepts a multiset with
--   precomputed size for performance reasons
selectNDistinctRandomElements :: Member RandomFu r => Int -> (IntMultiSet, Int) -> Sem r [Int]
selectNDistinctRandomElements n t@(ms, msSize)
    | n == msSize = return . map fst . IntMultiSet.toOccurList $ ms
    | msSize < n = error "Can't select n elements from a set with less than n elements"
    | otherwise = IntSet.toList <$> selectNDistinctRandomElementsWorker n t IntSet.empty

-- | Internal recursive worker for selectNDistinctRandomElements
--   Precondition: n > num distinct elems in multiset (not checked).
--   Does not terminate if the precondition doesn't apply.
--   This implementation is quite naive and selects elements randomly until
--   the predefined number of elements are set.
selectNDistinctRandomElementsWorker :: Member RandomFu r => Int -> (IntMultiSet, Int) -> IntSet -> Sem r IntSet
selectNDistinctRandomElementsWorker 0 _ current = return current
selectNDistinctRandomElementsWorker n t current = do
  randomElement <- selectRandomElement t
  let currentWithRE = IntSet.insert randomElement current
  if randomElement `IntSet.member` current
      then selectNDistinctRandomElementsWorker n t current
      else selectNDistinctRandomElementsWorker (n-1) t currentWithRE
