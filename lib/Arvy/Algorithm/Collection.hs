{-# LANGUAGE DeriveFunctor     #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns      #-}
module Arvy.Algorithm.Collection
  ( arrow
  , ivy
  , ring
  , RingNodeState(..)
  , minWeight
  , inbetween
  , inbetweenWeighted
  , module Data.Ratio
  , random
  , indexMeanScore
  , IndexMeanType(..)
  , localMinPairs
  , reclique
  , RecliqueConf(..)
  , dynamicStar
  ) where

import           Arvy.Algorithm
import           Arvy.Log
import           Data.Array.Unboxed
import           Data.Bifunctor
import           Data.Foldable
import           Data.IntMap                      (IntMap)
import qualified Data.IntMap                      as IntMap
import           Data.Maybe                       (fromMaybe)
import           Data.MonoTraversable
import qualified Data.NonNull                     as NN
import           Data.Ord                         (comparing)
import           Data.Random.Distribution.Uniform
import           Data.Random.RVar
import           Data.Ratio
import qualified Data.Sequence                    as S
import           Polysemy
import           Polysemy.RandomFu
import           Polysemy.State

newtype ArrowMessage i = ArrowMessage i deriving Show

arrow :: forall r . GeneralArvy r
arrow = GeneralArvy ArvySpec
  { arvyBehavior = behaviorType @r ArvyBehavior
    { arvyMakeRequest = \i _ -> return (ArrowMessage i)
    , arvyForwardRequest = \(ArrowMessage sender) i _ -> return (sender, ArrowMessage i)
    , arvyReceiveRequest = \(ArrowMessage sender) _ -> return sender
    }
  , arvyInitState = \_ _ -> return ()
  , arvyRunner = const raise
  }

{-# INLINE minWeight #-}
minWeight :: forall r . GeneralArvy r
minWeight = GeneralArvy spec where
  {-# INLINE spec #-}
  spec :: forall i . NodeIndex i => ArvySpec () i r
  spec = ArvySpec
    { arvyBehavior = behaviorType @(LocalWeights i ': r) ArvyBehavior
      { arvyMakeRequest = \i _ -> return [i]
      , arvyForwardRequest = \prevs i _ -> do
          weights <- traverse weightTo prevs
          let best = fst $ minimumBy (comparing snd) (zip prevs weights)
          return (best, i : map forward prevs)
      , arvyReceiveRequest = \prevs _ -> do
          weights <- traverse weightTo prevs
          return $ fst $ minimumBy (comparing snd) (zip prevs weights)
      }
    , arvyInitState = \_ _ -> return ()
    , arvyRunner = \weights -> reinterpret (weightHandler weights)
    }

newtype IvyMessage i = IvyMessage i deriving (Functor, Show)

-- | The Ivy Arvy algorithm, which always points all nodes back to the root node where the request originated from.
ivy :: forall r . GeneralArvy r
ivy = GeneralArvy ArvySpec
  { arvyBehavior = behaviorType @r ArvyBehavior
    { arvyMakeRequest = \i _ -> return (IvyMessage i)
    , arvyForwardRequest = \msg@(IvyMessage root) _ _ -> return (root, fmap forward msg)
    , arvyReceiveRequest = \(IvyMessage root) _ -> return root
    }
  , arvyInitState = \_ _ -> return ()
  , arvyRunner = const raise
  }


data RingMessage i
  = BeforeCrossing
      { root   :: i
      , sender :: i
      }
  | Crossing
      { root   :: i
      }
  | AfterCrossing
      { sender :: i
      }
  deriving Show

data RingNodeState
  = SemiNode
  | BridgeNode
  deriving Show

ring :: forall r . SpecializedArvy NodeCount RingNodeState r
ring = SpecializedArvy generator spec where
  generator :: NodeCount -> Sem r (ArvyData RingNodeState)
  generator n = return ArvyData
    { arvyDataNodeCount = n
    , arvyDataNodeData = \node -> ArvyNodeData
      { arvyNodeSuccessor = case node `compare` root of
          LT -> node + 1
          EQ -> node
          GT -> node - 1
      , arvyNodeAdditional = if node == root - 1
          then BridgeNode
          else SemiNode
      , arvyNodeWeights = \other ->
          let
            low = min node other
            mid = max node other
            high = low + n
            dist = min (mid - low) (high - mid)
          in fromIntegral dist
      }
    } where root = n `div` 2
  spec :: NodeIndex i => ArvySpec RingNodeState i r
  spec = ArvySpec
    { arvyBehavior = behaviorType @(State RingNodeState ': r) ArvyBehavior
      { arvyMakeRequest = \i _ -> get >>= \case
          -- If our initial node is part of a semi-circle, the message won't be crossing the bridge yet if at all
          SemiNode -> return (BeforeCrossing i i)
          -- If our initial node is the bridge node, the message will travel accross the bridge, and our current node will become a semi-circle one
          BridgeNode -> do
            put SemiNode
            return (Crossing i)

      , arvyForwardRequest = \msg i _ -> case msg of
          BeforeCrossing { root, sender } -> get >>= \case
            -- If we haven't crossed the bridge yet, and the message traverses through another non-bridge node
            SemiNode ->
              return (sender, BeforeCrossing (forward root) i)
            -- If however we're the bridge node, we send a crossing message and make the current node a semi-circle one
            BridgeNode -> do
              put SemiNode
              return (sender, Crossing (forward root))
          Crossing { root } -> do
            -- If we received a message saying that the bridge was just crossed, make the current node the next bridge start
            put BridgeNode
            return (root, AfterCrossing i)
          AfterCrossing { sender } ->
            return (sender, AfterCrossing i)

      , arvyReceiveRequest = \msg _ -> case msg of
          BeforeCrossing { sender } -> return sender
          Crossing { root } -> do
            put BridgeNode
            return root
          AfterCrossing { sender } -> return sender
      }
    , arvyInitState = \_ ArvyNodeData { .. } -> return arvyNodeAdditional
    , arvyRunner = const id
    }

newtype InbetweenMessage i = InbetweenMessage (S.Seq i) deriving (Functor, Show)

inbetween :: forall r . Ratio Int -> GeneralArvy r
inbetween ratio = GeneralArvy ArvySpec
  { arvyBehavior = behaviorType @r ArvyBehavior
    { arvyMakeRequest = \i _ -> return (InbetweenMessage (S.singleton i))
    , arvyForwardRequest = \(InbetweenMessage seq') i _ ->
      return (select seq', InbetweenMessage (fmap forward seq' S.|> i))
    , arvyReceiveRequest = \(InbetweenMessage seq') _ -> return (select seq')
    }
  , arvyInitState = \_ _ -> return ()
  , arvyRunner = const raise
  } where
  select :: S.Seq a -> a
  select s = s `S.index` floor (fromIntegral (S.length s - 1) * ratio)

newtype WeightedInbetweenMessage i = WeightedInbetweenMessage (NN.NonNull [(i, Double)]) deriving Show

-- | @'inbetweenWeighted' ratio@ Chooses the node that lies at @ratio@ inbetween the root node and the last node by weight,
-- where 0.0 means always choose the root node, 1.0 means always choose the last node
-- This is equivalent to 'inbetween' if run on a clique
inbetweenWeighted :: forall r . Double -> GeneralArvy r
inbetweenWeighted ratio = GeneralArvy spec where
  spec :: forall i . NodeIndex i => ArvySpec () i r
  spec = ArvySpec
    { arvyBehavior = behaviorType @(LocalWeights i ': r) ArvyBehavior
      { arvyMakeRequest = \i _ -> return (WeightedInbetweenMessage (opoint (i, 0)))
      , arvyForwardRequest = \msg@(WeightedInbetweenMessage ps@(NN.head -> (comingFrom, total))) i _ -> do
          newSucc <- select msg
          -- The newTotal is the previous total plus the weight to the node we're coming from
          newTotal <- (total+) <$> weightTo comingFrom
          return (newSucc, WeightedInbetweenMessage ((i, newTotal) NN.<| NN.mapNonNull (first forward) ps))
      , arvyReceiveRequest = \msg _ -> select msg
      }
    , arvyInitState = \_ _ -> return ()
    , arvyRunner = \weights -> reinterpret (weightHandler weights)
    } where
    select :: WeightedInbetweenMessage (Pred i) -> Sem (LocalWeights i ': r) (Pred i)
    select (WeightedInbetweenMessage ps@(NN.head -> (_, total))) = return newSucc where
      -- Find the first node that's less than ratio * total away, starting from the most recent node
      -- Nothing can't happen because desired is always >= 0, and ps will always contain the 0 element at the end
      Just (newSucc, _) = find ((<= total * ratio) . snd) (NN.toNullable ps)


random :: forall r . Member RandomFu r => GeneralArvy r
random = GeneralArvy ArvySpec
  { arvyBehavior = behaviorType @r ArvyBehavior
    { arvyMakeRequest = \i _ -> return (S.singleton i)
    , arvyForwardRequest = \s i _ -> do
        suc <- sampleRVar (randomSeq s)
        return (suc, fmap forward s S.|> i)
    , arvyReceiveRequest = \s _ -> sampleRVar (randomSeq s)
    }
  , arvyInitState = \_ _ -> return ()
  , arvyRunner = const raise
  }

-- | Selects a random element from a 'Seq' in /O(log n)/
randomSeq :: S.Seq a -> RVar a
randomSeq s = do
  i <- uniformT 0 (S.length s - 1)
  return $ S.index s i



--newtype UtilityFunMessage i = UtilityFunMessage (NonNull [(Int, i)]) deriving Show
--
--utilityFun :: forall s r a . (Show s, Ord a) => (Int -> Double -> a) -> Arvy s r
--utilityFun f = arvy @UtilityFunMessage ArvyInst
--  { arvyInitiate = \i _ -> return $ UtilityFunMessage (opoint (0, i))
--  , arvyTransmit = \msg@(UtilityFunMessage xs) i _ -> do
--      best <- select msg
--      let newElem = (fst (head xs) + 1, i)
--      return (best, UtilityFunMessage $ newElem <| mapNonNull (second forward) xs)
--  , arvyReceive = \msg _ -> select msg
--  } where
--  select :: ArvySelector UtilityFunMessage s r
--  select (UtilityFunMessage xs) = do
--    let (indices, ids) = unzip (otoList xs)
--    weights <- traverse weightTo ids
--    let values = zipWith3 (\p d w -> (p, f d w)) ids indices weights
--        best = fst $ minimumBy (comparing snd) values
--    return best
--
---- TODO: Special functions for utility functions `w * (1 + m * (1 - e ^ (-a * i)))` and `w * ln (i * a)`

data IndexMean
  = NoIndices
  | IndexMean Double Int
  deriving Show

type IndexMeanState = (IndexMean, Int)

initialIndexMeanState :: IndexMeanState
initialIndexMeanState = (NoIndices, 0)

logWeight :: Double -> IndexMean -> IndexMean
logWeight w NoIndices = IndexMean w 1
logWeight w (IndexMean x n) = IndexMean (adjustedX * adjustedI) (n + 1) where
  n' = fromIntegral n
  adjustedX = x ** (n' / (n' + 1))
  adjustedI = w ** (1 / (n' + 1))

getIndexScore :: IndexMean -> Maybe Double
getIndexScore NoIndices       = Nothing
getIndexScore (IndexMean x _) = Just x

data IndexMeanType
  = HopIndexBased
  | WeightSumBased
  deriving Show

data IndexMeanMessage i = IndexMeanMessage Double [(i, Maybe Double)] deriving Show

{- |
Algorithm that logs indices of request paths at nodes, aggregating them with the geometric mean which then influences which nodes get selected.
-}
indexMeanScore :: forall r . LogMember r => IndexMeanType -> (Int -> Double) -> GeneralArvy r
indexMeanScore ty af = GeneralArvy spec where
  {-# INLINE spec #-}
  spec :: forall i . NodeIndex i => ArvySpec () i r
  spec = ArvySpec
    { arvyBehavior = behaviorType @(LocalWeights (Succ i) ': State IndexMeanState ': r) ArvyBehavior
      { arvyMakeRequest = \i s -> do
          (indexMean, _) <- get
          w <- edgePart s
          return (IndexMeanMessage w (opoint (i, getIndexScore indexMean)))
      , arvyForwardRequest = \msg@(IndexMeanMessage w xs) i s -> do
          best <- select msg
          w' <- edgePart s
          indexMean <- gets fst
          let newMessage = IndexMeanMessage (w + w') ((i, getIndexScore indexMean) : map (first forward) xs)
          return (best, newMessage)
      , arvyReceiveRequest = \msg _ -> do
          best <- select msg
          modify (second (+1))
          return best
      }
    , arvyInitState = \_ _ -> return initialIndexMeanState
    , arvyRunner = \weights -> interpret (weightHandler weights)
    } where

    {-# INLINE edgePart #-}
    edgePart :: forall r' . Member (LocalWeights (Succ i)) r' => Succ i -> Sem r' Double
    edgePart = case ty of
      HopIndexBased  -> \_ -> return 1
      WeightSumBased -> weightTo


    {-# INLINE select #-}
    select :: IndexMeanMessage (Pred i) -> Sem (LocalWeights (Succ i) ': State IndexMeanState ': r) (Pred i)
    select (IndexMeanMessage w xs) = do
      (oldIndexMean, k) <- get
      let a = af k
      let newIndexMean = logWeight w oldIndexMean
      put (newIndexMean, k)
      scores <- traverse (\(i, iScore) -> do
                              weight <- weightTo i
                              return (i, getScore a iScore weight)
                          ) xs
      return $ fst $ minimumBy (comparing snd) scores


  {-# INLINE getScore #-}
  getScore :: Double -> Maybe Double -> Double -> Double
  getScore _ Nothing weight       = weight
  getScore a (Just iScore) weight = weight ** a * iScore ** (1 - a)




data LocalMinPairsMessage i = LocalMinPairsMessage [(i, Double)] [UArray Int Double] deriving Show


localMinPairs :: forall r . LogMember r => GeneralArvy r
localMinPairs = GeneralArvy spec where
  spec :: forall i . NodeIndex i => ArvySpec () i r
  spec = ArvySpec
    { arvyBehavior = behaviorType @(LocalWeights i ': r) ArvyBehavior
      { arvyMakeRequest = \i _ -> return (LocalMinPairsMessage [(i, 0)] [listArray (0, 0) [0]])
      , arvyForwardRequest = \(LocalMinPairsMessage nodes dists) i _ -> do
          let count = length nodes
          --trace $ "We are at count " ++ show count
          weights <- zipWith3 (\k (j, score) weight -> (k, j, score, weight * fromIntegral count + score)) [0 :: Int ..] nodes <$> traverse (weightTo.fst) nodes
          --trace $ "Scores determined to be " ++ show weights
          let (bestIndex, best, bestScore, _) = minimumBy (comparing (\(_, _, _, d) -> d)) weights
          bestWeight <- weightTo best
          --trace $ "Selected node at index " ++ show bestIndex ++ " with node score " ++ show bestScore ++ " and weight " ++ show bestWeight

          let getDist u v
                | u == v = 0
                | u > v = getDist v u
                | otherwise = dists !! v ! u

          let newWeights = listArray (0, count - 1) (map (\j -> getDist j bestIndex + bestWeight) [0 :: Int ..])
          --trace $ "New weights are " ++ show newWeights
          let newDists = dists ++ [newWeights]

          let newNodes = map (\(j, (n, s)) -> (forward n, s + newWeights ! j)) (zip [0 :: Int ..] nodes)
          --trace $ "Updated old node scores to " ++ show newNodes
          let newNodeScore = bestScore + fromIntegral count * bestWeight
          let newNodes' = newNodes ++ [(i, newNodeScore)]
          --trace $ "Added new node score " ++ show newNodeScore

          --let newNodes' =
          --let newArray = array ((0, 0), (count, count)) []

          return (best, LocalMinPairsMessage newNodes' newDists)
      , arvyReceiveRequest = \(LocalMinPairsMessage nodes _) _ -> do
          let count = length nodes
          --trace $ "We are at the final count " ++ show count
          weights <- zipWith (\(j, score) weight -> (j, weight * fromIntegral count + score)) nodes <$> traverse (weightTo.fst) nodes
          let best = fst $ minimumBy (comparing snd) weights
          return best
      }
    , arvyInitState = \_ _ -> return ()
    , arvyRunner = \weights -> reinterpret (weightHandler weights)
    }

-- | Configuration for a recursive clique
data RecliqueConf = RecliqueConf
  { recliqueFactor :: Double
  -- ^ How much the distance increases with an additional level, should be > 1
  , recliqueLevels :: Int
  -- ^ How many levels there should be
  , recliqueBase   :: Int
  -- ^ How many more nodes each level has
  } deriving (Show)

-- | How many nodes a reclique has
recliqueNodeCount :: RecliqueConf -> NodeCount
recliqueNodeCount RecliqueConf { .. } = recliqueBase ^ recliqueLevels

recliqueLayers :: RecliqueConf -> Node -> [Int]
recliqueLayers RecliqueConf { .. } = reverse . go recliqueLevels where
  go :: Int -> Int -> [Int]
  go 0 _ = []
  go k x = b : go (k - 1) a where
    (a, b) = divMod x recliqueBase

recliqueUnlayers :: RecliqueConf -> [Int] -> Node
recliqueUnlayers RecliqueConf { .. } = foldl (\acc el -> acc * recliqueBase + el) 0

-- | A recursive clique graph. This is a clique of `recliqueBase` nodes, where each node contains a clique of `recliqueBase` nodes itself, and so on, `recliqueLevels` deep. Different nodes that are in the same lowest layer have distance 1 between them. Nodes in a different lowest layer but the same second-lowest layer have distance `recliqueFactor` between them, one layer up distance `recliqueFactor ^^ 2`, and so on.
recliqueWeights :: RecliqueConf -> Node -> Node -> Weight
recliqueWeights RecliqueConf { .. } u v
  | u == v = 0
  | otherwise = recliqueFactor ^^ (dist u v - 1)
  where
    dist :: Int -> Int -> Int
    dist a b
      | a == b = 0
      | otherwise = 1 + dist (div a recliqueBase) (div b recliqueBase)


recliqueInitialState :: RecliqueConf -> Node -> Maybe Int
recliqueInitialState _ 0 = Nothing
recliqueInitialState conf@RecliqueConf { .. } node = rightmostZero $ reverse (recliqueLayers conf node) where
  rightmostZero :: [Int] -> Maybe Int
  rightmostZero []     = Nothing
  rightmostZero (0:xs) = (+1) <$> rightmostZero xs
  rightmostZero _      = Just 0


recliqueSuccessor :: RecliqueConf -> Node -> Node
recliqueSuccessor conf node = recliqueUnlayers conf newLayers where
  layers = recliqueLayers conf node
  newLayers = reverse $ zeroLeftmost $ reverse layers
  zeroLeftmost :: [Int] -> [Int]
  zeroLeftmost []     = []
  zeroLeftmost (0:xs) = 0 : zeroLeftmost xs
  zeroLeftmost (_:xs) = 0 : xs

data RecliqueMessage i = RecliqueMessage Int i (IntMap i) deriving Show

{-# INLINE reclique #-}
reclique :: forall r . SpecializedArvy RecliqueConf (Maybe Int) r
reclique = SpecializedArvy gen spec where
  gen :: RecliqueConf -> Sem r (ArvyData (Maybe Int))
  gen conf = return ArvyData
    { arvyDataNodeCount = recliqueNodeCount conf
    , arvyDataNodeData = \node -> ArvyNodeData
      { arvyNodeSuccessor = recliqueSuccessor conf node
      , arvyNodeAdditional = recliqueInitialState conf node
      , arvyNodeWeights = recliqueWeights conf node
      }
    }
  {-# INLINE spec #-}
  spec :: forall i . NodeIndex i => ArvySpec (Maybe Int) i r
  spec = ArvySpec
    { arvyBehavior = behaviorType @(State (Maybe Int) ': r) @RecliqueMessage ArvyBehavior
      { arvyMakeRequest = \i _ -> do
          thisLevel <- fromMaybe (error "Bug in the arvy runner, makeRequest called for the root") <$> get
          put Nothing
          return (RecliqueMessage thisLevel i IntMap.empty)
      , arvyForwardRequest = \(RecliqueMessage recvLevel root levelMap) i _ -> do
          let newSucc = IntMap.findWithDefault root recvLevel levelMap
          let newLevelMap = foldr (\el acc -> IntMap.insert el i acc) (fmap forward levelMap) [0..recvLevel - 1]
          thisLevel <- fromMaybe (error "Bug in the arvy runner, forwardRequest called for the root") <$> get
          put (Just recvLevel)
          return (newSucc, RecliqueMessage thisLevel (forward root) newLevelMap)
      , arvyReceiveRequest = \(RecliqueMessage recvLevel root levelMap) _ -> do
          let newSucc = IntMap.findWithDefault root recvLevel levelMap
          put (Just recvLevel)
          return newSucc
      }
    , arvyInitState = \_ -> return . arvyNodeAdditional
    , arvyRunner = const id
    }


type DynamicStarState i = UArray i Int
data DynamicStarMessage i = DynamicStarMessage
  { dynStarMsgRoot      :: !i
  , dynStarMsgRootCount :: !Int
  , dynStarMsgBest      :: !i
  , dynStarMsgBestScore :: !Double
  } deriving Show


{-# INLINE dynamicStar #-}
dynamicStar :: forall r . LogMember r => GeneralArvy r
dynamicStar = GeneralArvy spec where
  {-# INLINE spec #-}
  spec :: forall i . NodeIndex i => ArvySpec () i r
  spec = ArvySpec
    { arvyBehavior = behaviorType @(LocalWeights i ': State (DynamicStarState i) ': r) ArvyBehavior
      { arvyMakeRequest = \i _ -> do
          newCount <- (+1) <$> gets (! i)
          modify (// [(i, newCount)])
          DynamicStarMessage i newCount i <$> getLocalScore
      , arvyForwardRequest = \DynamicStarMessage { .. } i _ -> do
          modify (// [(forward dynStarMsgRoot, dynStarMsgRootCount)])
          score <- getLocalScore
          let (newBest, newBestScore) = case dynStarMsgBestScore `compare` score of
                GT -> (i, score)
                _  -> (forward dynStarMsgBest, dynStarMsgBestScore)
          return ( dynStarMsgBest
                 , DynamicStarMessage (forward dynStarMsgRoot) dynStarMsgRootCount newBest newBestScore)
      , arvyReceiveRequest = \DynamicStarMessage { .. } _ -> do
          modify (// [(forward dynStarMsgRoot, dynStarMsgRootCount)])
          return dynStarMsgBest
      }
    , arvyInitState = \nodeCount _ ->
        return (listArray (0, nodeCount - 1) (replicate nodeCount 0) :: UArray Node Int)
    , arvyRunner = \weights -> interpret (weightHandler weights)
    } where
    {-# INLINE getLocalScore #-}
    getLocalScore :: Sem (LocalWeights i ': State (DynamicStarState i) ': r) Double
    getLocalScore = do
      arr <- get
      weights <- allWeights
      lgDebug $ "Counts: " <> tshow (elems arr)
      lgDebug $ "Weights: " <> tshow (elems weights)
      let total = sum $ elems arr
          nodeRange = bounds arr
          summands =
            [ fromIntegral (arr ! u) * fromIntegral (arr ! v) * (weights ! u + weights ! v)
            | u <- range nodeRange
            , v <- range nodeRange
            , index nodeRange u < index nodeRange v
            ]
          score = sum summands / fromIntegral total ^^ (2 :: Int)
      lgDebug $ "Score: " <> tshow score
      return score
