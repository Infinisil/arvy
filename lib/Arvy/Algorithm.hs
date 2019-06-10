{-# LANGUAGE AllowAmbiguousTypes       #-}
{-# LANGUAGE QuantifiedConstraints       #-}
{-# LANGUAGE DataKinds                 #-}
{-# LANGUAGE DefaultSignatures         #-}
{-# LANGUAGE DeriveFunctor             #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE NamedFieldPuns            #-}
{-# LANGUAGE RankNTypes                #-}
{-# LANGUAGE RecordWildCards           #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE TypeApplications          #-}
{-# LANGUAGE TypeFamilies              #-}
{-# LANGUAGE TypeOperators             #-}

module Arvy.Algorithm where

import           Arvy.Weights
import           Arvy.Tree
import           Arvy.Requests
import           Data.Array.MArray
import           Data.Array.IO
import           Polysemy
import           Polysemy.Input
import           Polysemy.Reader
import           Polysemy.Output
import           Polysemy.Trace
import           Polysemy.State
import           Polysemy.Random


{- |
An Arvy algorithm, a combination between Arrow and Ivy.
@r@ stands for the effects it runs in, chosen by the caller, but the algorithm can enforce certain constraints on it, like requiring randomness.
@msg@ stands for the message type it sends between nodes, this can be arbitrarily chosen by the algorithm.
@i@ stands for the node index type, which can be passed via messages and be has to be used to select which node to choose as the next successor.

- When a node @x@ initiates a request, 'arvyInitiate' is called to generate the initial message, which has access to the current node's index through a 'Reader i' effect.
- This message gets passed along the path from @x@ to the current token holder @y@. For nodes the request travels *through*, 'arvyTransmit' is called, which can transform the message, potentially adding a reference to the current node's index.
- Whenever a message arrives at a node, 'arvySelect' is called, which has to select a node index from the received message. For this selection, the algorithm does *not* have access to the current node's index. This is to ensure correctness of it, because only *previously* traversed nodes should be selected.

-}

data Env i = Env
  { nodeIndex      :: i
  , nodeCount      :: Int
  , neigborWeights :: Int -> Double
  }



data Arvy r = forall msg s . Arvy
  { arvyNodeInit :: forall i . ToIx i => i -> Sem r s
  -- ^ How to compute the initial state in all nodes
  , arvyInitiate :: forall i . ToIx i => i -> Sem (State s ': r) (msg i)
  -- ^ Initial request message contents
  -- Accessible is the state of the node that sends the message and the index of it
  , arvyTransmit :: forall i' i . TIx i' i => i -> msg i' -> Sem (State s ': r) (i', msg i)
  -- ^ How to transmit a message when a node received one and has to pass it on
  -- Accessible is the state of the node that receive the mess
  , arvyReceive :: forall i' i . TIx i' i => i -> msg i' -> Sem (State s ': r) i'
  -- ^ How to determine the new successor from a received message, this is the meat of an Arvy algorithm
  -- Accessible is the state of the node that received the message and the index of it
  -- However you can't use the index of the current node as a return value in order to ensure correctness of Arvy.
  }

data ExpandedArvy r msg s = ExpandedArvy
  { arvyNodeInit' :: forall i . ToIx i => i -> Sem r s
  , arvyInitiate' :: forall i . ToIx i => i -> Sem (State s ': r) (msg i)
  , arvyTransmit' :: forall i' i . TIx i' i => i -> msg i' -> Sem (State s ': r) (i', msg i)
  , arvyReceive' :: forall i' i . TIx i' i => i -> msg i' -> Sem (State s ': r) i'
  }


-- TODO: Use mono-traversable for speedup
superSimpleArvy :: (forall i . [i] -> Sem r i) -> Arvy r
superSimpleArvy selector = Arvy
  { arvyNodeInit = \_ -> return ()
  , arvyInitiate = \i -> return [i]
  , arvyTransmit = \i msg -> do
      s <- raise $ selector msg
      return (s, i : fmap forwarded msg)
  , arvyReceive = \_ msg ->
      raise $ selector msg
  }

newtype ArrowMessage i = ArrowMessage i

arrow :: Arvy r
arrow = Arvy
  { arvyNodeInit = \_ -> return ()
  , arvyInitiate = return . ArrowMessage
  , arvyTransmit = \i (ArrowMessage sender) ->
      return (sender, ArrowMessage i)
  , arvyReceive = \_ (ArrowMessage sender) ->
      return sender
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

data RingNodeState
  = SemiNode
  | BridgeNode

constantRing :: forall r . Int -> Arvy r
constantRing firstBridge = Arvy
  { arvyNodeInit = \i -> return $
    if toIx i == firstBridge
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
          return (sender, BeforeCrossing (forwarded root) i)
        BridgeNode -> do
          put SemiNode
          return (sender, Crossing (forwarded root))
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

newtype IvyMessage i = IvyMessage i

ivy :: Arvy r
ivy = Arvy
  { arvyNodeInit = \_ -> return ()
  , arvyInitiate = return . IvyMessage
  , arvyTransmit = \_ (IvyMessage root) ->
      return (root, IvyMessage (forwarded root))
  , arvyReceive = \_ (IvyMessage root) ->
      return root
  }

class (ToIx a, ToIx b) => TIx a b where
  forwarded :: a -> b
  default forwarded :: a ~ b => a -> b
  forwarded = id

instance TIx Int Int

class ToIx a where
  toIx :: a -> Int

instance ToIx Int where
  toIx = id


main :: IO ()
main = do
  let count = 1000
  weights <- runM $ runRandomIO $ randomWeights count
  requests <- runM $ runRandomIO $ randomRequests count 1000
  tree <- mst count weights :: IO (IOArray Int (Maybe Int))
  runM
    $ runTraceIO
    $ runOutputAsTrace @(Int, Int)
    $ runListInput requests
    $ runArvyLocal @IO @IOArray count tree ivy
  

  return ()


runArvyLocal
  :: forall m narr r tarr
  . ( Members '[ Input (Maybe Int)
               , Lift m
               , Trace
               , Output (Int, Int) ] r
    , MArray tarr (Maybe Int) m
    , forall s . MArray narr s m)
  => Int
  -> tarr Int (Maybe Int)
  -> Arvy r
  -> Sem r ()
runArvyLocal count tree Arvy { .. } = runArvyLocal' $ ExpandedArvy arvyNodeInit arvyInitiate arvyTransmit arvyReceive where
  runArvyLocal'
    :: forall msg s
    . (Members '[ Input (Maybe Int)
                , Lift m
                , Trace
                , Output (Int, Int) ] r
      , MArray tarr (Maybe Int) m
      , MArray narr s m)
    => ExpandedArvy r msg s
    -> Sem r ()
  runArvyLocal' ExpandedArvy { .. } = do
    x <- traverse arvyNodeInit' [0 .. count - 1]
    res <- sendM @m $ newListArray (0, count - 1) x
    go res
    where
      go
        :: (Members '[ Input (Maybe Int)
                     , Lift m
                     , Trace
                     , Output (Int, Int) ] r)
         => narr Int s
         -> Sem r ()
      go state = input @(Maybe Int) >>= \case
        Nothing -> trace "All requests fulfilled"
        Just i -> do
          trace $ "Request from node " ++ show i
          sendM @m (readArray tree i) >>= \case
            Nothing -> trace "This node already has the token"
            Just successor -> do
              oldState <- sendM @m (readArray state i)
              (newState, msg) <- runState oldState (arvyInitiate' i)
              sendM @m (writeArray state i newState)
              sendM @m (writeArray tree i Nothing)
              output (i, successor)
              send msg successor
          go state
        where
          send :: (Members '[ Lift m
                            , Trace
                            , Output (Int, Int) ] r)
                => msg Int -> Int -> Sem r ()
          send msg i = do
            sendM @m (readArray tree i) >>= \case
              Nothing -> do
                oldState <- sendM @m (readArray state i)
                (newState, newSucc) <- runState oldState (arvyReceive' i msg)
                sendM @m (writeArray state i newState)
                sendM @m (writeArray tree i (Just newSucc))
              Just successor -> do
                oldState <- sendM @m (readArray state i)
                (newState, (newSucc, newMsg)) <- runState oldState (arvyTransmit' i msg)
                sendM @m (writeArray state i newState)
                sendM @m (writeArray tree i (Just newSucc))
                output (i, successor)
                send newMsg successor
  
--runArvyLocal weights tree alg@Arvy { .. } = input @(Maybe Word) >>= \case
--  Nothing -> return ()
--  Just index -> do
--    sendM @m (readArray tree index) >>= \case
--      Nothing -> return ()
--      Just succ -> do
--        return ()
--    runArvyLocal @m weights tree alg
      --res <- sendM @m $ newListArray @arr' (0, count - 1) x


  --{ arvyNodeInit :: forall i . ToIx i => i -> Sem r s
  ---- ^ How to compute the initial state in all nodes
  --, arvyInitiate :: forall i . ToIx i => i -> Sem (State s ': r) (msg i)
  ---- ^ Initial request message contents
  ---- Accessible is the state of the node that sends the message and the index of it
  --, arvyTransmit :: forall i' i . TIx i' i => i -> msg i' -> Sem (State s ': r) (i', msg i)
  ---- ^ How to transmit a message when a node received one and has to pass it on
  ---- Accessible is the state of the node that receive the mess
  --, arvyReceive :: forall i' i . TIx i' i => i -> msg i' -> Sem (State s ': r) i'
--runArvyLocal :: forall i r . Members '[Trace, SpanningTree i, Output (i, i)] r => Arvy r -> i -> Sem r ()
--runArvyLocal (Arvy n s t rr) = runArvyLocal' (n, s, t, rr) where
--  runArvyLocal' :: forall i r msg n
--    . Members '[Trace, SpanningTree i, Output (i, i)] r
--    => ( Sem (Reader i ': r) n
--       , Sem (State n ': Reader i ': r) (msg i)
--       , msg i -> Sem (State n ': Reader i ': r) (msg i)
--       , msg i -> Sem (State n ': r) i
--       )
--    -> i
--    -> Sem r ()
--  runArvyLocal' (nodeInit, send, transfer, select) r = do
--    trace "Initiating request"
--    getSuccessor r >>= \case
--      Nothing -> trace "Token is already here\n"
--      Just n -> do
--        setSuccessor r Nothing
--        (_, msg) <- runReader r (runState undefined send)
--        output (r, n)
--        go msg n
--    where
--      go :: msg i -> i -> Sem r ()
--      go msg r = do
--        (_, nextSucc) <- runState undefined $ select msg
--        currentSucc <- getSuccessor r
--        setSuccessor r (Just nextSucc)
--        case currentSucc of
--          Nothing ->
--            trace "Request arrived at token holder\n"
--          Just n -> do
--            (_, newMsg) <- runReader r $ runState undefined $ transfer msg
--            output (r, n)
--            go newMsg n

