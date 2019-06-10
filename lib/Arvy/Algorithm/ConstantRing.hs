{-# LANGUAGE LambdaCase     #-}
{-# LANGUAGE NamedFieldPuns #-}
module Arvy.Algorithm.ConstantRing where

import           Arvy.Algorithm

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

data RingNodeState
  = SemiNode
  | BridgeNode

constantRing :: Int -> Arvy r
constantRing firstBridge = Arvy
  { arvyNodeInit = \i -> return $
    if indexValue i == firstBridge
        then BridgeNode
        else SemiNode

  , arvyInitiate = \i -> get >>= \case
      SemiNode -> return (BeforeCrossing i i)
      BridgeNode -> do
        put SemiNode
        return (Crossing i)

  , arvyTransmit = \i -> \case
      BeforeCrossing { root, sender } -> get >>= \case
        SemiNode ->
          return (sender, BeforeCrossing (forward root) i)
        BridgeNode -> do
          put SemiNode
          return (sender, Crossing (forward root))
      Crossing { root } -> do
        put BridgeNode
        return (root, AfterCrossing i)
      AfterCrossing { sender } ->
        return (sender, AfterCrossing i)

  , arvyReceive = \_ -> \case
      BeforeCrossing { sender } -> return sender
      Crossing { root } -> do
        put BridgeNode
        return root
      AfterCrossing { sender } -> return sender
  }
