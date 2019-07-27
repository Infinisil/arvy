{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE StandaloneDeriving #-}
module Arvy.Algorithm.Collection
  ( arrow, ivy, half, constantRing, inbetween, random
  , RingNodeState(..)
  ) where

import Arvy.Algorithm
import Data.Sequences
import Data.NonNull
import Data.Ratio
import qualified Data.Sequence as S
import Data.Sequence (Seq, (|>), ViewL(..))
import Polysemy
import Polysemy.RandomFu
import Data.Random

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
  , arvyTransmit = \(IvyMessage root) i _ ->
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
  , arvyTransmit = \(InbetweenMessage k f (fmap forward -> seq)) i _ ->
      let s = S.length seq + 1
          newK = k + 1
          (newF, newSeq) = if (newK - s) % newK < ratio
            then case S.viewl seq of
              EmptyL -> (i, S.empty)
              fir :< rest -> (fir, rest |> i)
            else (forward f, seq |> i)
      in return (f, InbetweenMessage newK newF newSeq)
  , arvyReceive = \(InbetweenMessage _ f _) _ -> return f
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
