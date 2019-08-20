{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE DeriveFunctor #-}
module Arvy.Algorithm.Collection
  ( arrow
  , ivy
  , half
  , constantRing
  , inbetween
  , random
  , genArrow
  , inbetweenWeighted
  , utilityFun
  , RingNodeState(..)
  ) where

import Arvy.Algorithm
import Data.Sequences
import Data.NonNull hiding (minimumBy)
import Data.Ratio
import qualified Data.Sequence as S
import Data.Sequence (Seq, (|>), ViewL(..))
import Polysemy
import Polysemy.RandomFu
import Data.Random
import Data.MonoTraversable
import Data.Ord (comparing)
import Prelude hiding (head)
import Data.Bifunctor
import Data.List (minimumBy)

genArrow :: forall s r . Show s => Arvy s r
genArrow = simpleArvy $ \xs -> do
  weights <- traverse (\i -> (i,) <$> weightTo i) (otoList xs)
  return $ fst $ minimumByEx (comparing snd) weights

newtype ArrowMessage i = ArrowMessage i deriving Show

-- | The Arrow Arvy algorithm, which always inverts all edges requests travel through. The shape of the tree therefore always stays the same
arrow :: forall s r . Show s => Arvy s r
arrow = arvy @ArrowMessage @s ArvyInst
  { arvyInitiate = \i _ -> return (ArrowMessage i)
  , arvyTransmit = \(ArrowMessage sender) i _ ->
      return (sender, ArrowMessage i)
  , arvyReceive = \(ArrowMessage sender) _ ->
      return sender
  }


newtype IvyMessage i = IvyMessage i deriving Show

-- | The Ivy Arvy algorithm, which always points all nodes back to the root node where the request originated from.
ivy :: forall s r . Show s => Arvy s r
ivy = arvy @IvyMessage @s ArvyInst
  { arvyInitiate = \i _ -> return (IvyMessage i)
  , arvyTransmit = \(IvyMessage root) _ _ ->
      return (root, IvyMessage (forward root))
  , arvyReceive = \(IvyMessage root) _ ->
      return root
  }

-- | An Arvy algorithm that always chooses the node in the middle of the traveled through path as the new successor.
half :: Show s => Arvy s r
half = simpleArvy middle where
  middle xs = return $ xs' `unsafeIndex` (lengthIndex xs' `div` 2) where
    xs' = toNullable xs

data InbetweenMessage i = InbetweenMessage Int i (Seq i) deriving (Functor, Show)

inbetween :: forall s r . Show s => Ratio Int -> Arvy s r
inbetween ratio = arvy @InbetweenMessage @s ArvyInst
  { arvyInitiate = \i _ -> return (InbetweenMessage 1 i S.empty)
  , arvyTransmit = \(InbetweenMessage k f (fmap forward -> seq')) i _ ->
      let s = S.length seq' + 1
          newK = k + 1
          (newF, newSeq) = if (newK - s) % newK < ratio
            then case S.viewl seq' of
              EmptyL -> (i, S.empty)
              fir :< rest -> (fir, rest |> i)
            else (forward f, seq' |> i)
      in return (f, InbetweenMessage newK newF newSeq)
  , arvyReceive = \(InbetweenMessage _ f _) _ -> return f
  }

newtype WeightedInbetweenMessage i = WeightedInbetweenMessage (NonNull [(i, Double)]) deriving Show

-- | @'inbetweenWeighted' ratio@ Chooses the node that lies at @ratio@ inbetween the root node and the last node by weight,
-- where 0.0 means always choose the root node, 1.0 means always choose the last node
-- This is equivalent to 'inbetween' if run on a clique
inbetweenWeighted :: forall s r . Show s => Double -> Arvy s r
inbetweenWeighted ratio = arvy @WeightedInbetweenMessage @s ArvyInst
  { arvyInitiate = \i _ -> return (WeightedInbetweenMessage (opoint (i, 0)))
  , arvyTransmit = \(WeightedInbetweenMessage ps@(head -> (comingFrom, total))) i _ -> do
      -- Find the first node that's less than ratio * total away, starting from the most recent node
      -- Nothing can't happen because desired is always >= 0, and ps will always contain the 0 element at the end
      let Just (newSucc, _) = find ((<= total * ratio) . snd) ps
      -- The newTotal is the previous total plus the weight to the node we're coming from
      newTotal <- (total+) <$> weightTo comingFrom
      return (newSucc, WeightedInbetweenMessage ((i, newTotal) <| mapNonNull (first forward) ps))
  , arvyReceive = \(WeightedInbetweenMessage ps@(head -> (_, total))) _ -> do
      let Just (newSucc, _) = find ((<= total * ratio) . snd) ps
      return newSucc
  }


random :: forall s r . (Member RandomFu r, Show s) => Arvy s r
random = arvy @Seq @s ArvyInst
  { arvyInitiate = \i _ -> return (S.singleton i)
  , arvyTransmit = \s i _ -> do
      suc <- sampleRVar (randomSeq s)
      return (suc, fmap forward s |> i)
  , arvyReceive = \s _ ->
      sampleRVar (randomSeq s)
  }

-- | Selects a random element from a 'Seq' in /O(log n)/
randomSeq :: Seq a -> RVar a
randomSeq s = do
  i <- uniformT 0 (S.length s - 1)
  return $ S.index s i


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

-- TODO: Redesign parameters such that Arvy algorithms can specify an initial tree
-- | An Arvy algorithm that runs in constant competitive ratio on ring graphs. It works by splitting the ring into two semi-circles, connected by a bridge. The semi-circles are always kept intact, but whenever the bridge is traversed, the root node is selected as the new bridge end, while the previous bridge end becomes the new bridge start.
constantRing :: Arvy RingNodeState r
constantRing = arvy @RingMessage @RingNodeState ArvyInst
  { arvyInitiate = \i _ -> get >>= \case
      -- If our initial node is part of a semi-circle, the message won't be crossing the bridge yet if at all
      SemiNode -> return (BeforeCrossing i i)
      -- If our initial node is the bridge node, the message will travel accross the bridge, and our current node will become a semi-circle one
      BridgeNode -> do
        put SemiNode
        return (Crossing i)

  , arvyTransmit = \msg i _ -> case msg of
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

  , arvyReceive = \msg _ -> case msg of
      BeforeCrossing { sender } -> return sender
      Crossing { root } -> do
        put BridgeNode
        return root
      AfterCrossing { sender } -> return sender
  }

newtype UtilityFunMessage i = UtilityFunMessage (NonNull [(Int, i)]) deriving Show

utilityFun :: forall s r a . (Show s, Ord a) => (Int -> Double -> a) -> Arvy s r
utilityFun f = arvy @UtilityFunMessage ArvyInst
  { arvyInitiate = \i _ -> return $ UtilityFunMessage (opoint (0, i))
  , arvyTransmit = \(UtilityFunMessage xs) i _ -> do
      best <- select xs
      let newElem = (fst (head xs) + 1, i)
      return (best, UtilityFunMessage $ newElem <| mapNonNull (second forward) xs)
  , arvyReceive = \(UtilityFunMessage xs) _ -> select xs
  } where
  select
    :: forall r' i
     . ( NodeIndex i
       , Member (LocalWeights (Succ i)) r' )
    => NonNull [(Int, Pred i)]
    -> Sem r' (Pred i)
  select xs = do
    let (indices, ids) = unzip (otoList xs)
    weights <- traverse weightTo ids
    let values = zipWith3 (\p d w -> (p, f d w)) ids indices weights
        best = fst $ minimumBy (comparing snd) values
    return best
