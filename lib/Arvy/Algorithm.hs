{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveFunctor          #-}
{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE TypeFamilies           #-}
{- |
Description : Arvy algorithm abstraction
Copyright   : (c) Silvan Mosberger, 2019
License     : GPL-3
Maintainer  : contact@infinisil.com
Stability   : experimental

This module contains an abstract definition of an Arvy algorithm (Pankaj Khanchandani and Roger Wattenhofer \"/The Arvy Distributed Directory Protocol/\", The 31st ACM Symposium on Parallelism in Algorithms and Architectures, Pages 225-235, <https://dl.acm.org/citation.cfm?id=3323181>).
-}

module Arvy.Algorithm
  ( ArvyBehavior(..)
  , ArvySpec(..)
  , behaviorType
  , Forwardable(..)
  , NodeIndex(..)
  , ArvyData(..)
  , ArvyNodeData(..)
  , Node
  , NodeCount
  , GeneralArvy(..)
  , SpecializedArvy(..)
  , Weight
  , LocalWeights(..)
  , weightTo
  , weightHandler
  ) where

import Polysemy
import Polysemy.State

{- |
An Arvy heuristic for a dynamic algorithm.

- @i@ is the node index type, this should stay polymorphic.
- @msg :: * -> *@ is the type of request messages passed between nodes, parametrized by the node index type.
- @r@ is the effects the algorithm runs in, which can include effects parametrized by @i@.
-}
data ArvyBehavior i msg r = ArvyBehavior
  { arvyMakeRequest :: i -> Succ i -> Sem r (msg i)
  -- ^ 'dynamicArvyMakeRequest cur succ' determines what message should be sent to the successor node @succ@ when some node @cur@ makes a request for the token.
  , arvyForwardRequest :: msg (Pred i) -> i -> Succ i -> Sem r (Pred i, msg i)
  -- ^ @'dynamicArvyForwardRequest' msg cur succ@ determines both what message should be forwarded to the successor node @succ@ when some node @cur@ received a token request message @msg@ and what @cur@'s new successor should be. For correctness guarantees, only previously traversed nodes can be selected. This is enforced by @i@ only allowing node indices to be forwarded one way, from @'Pred' i@ to @i@ to @'Succ' i@ (which can be done with the 'forward' function).
  , arvyReceiveRequest :: msg (Pred i) -> i -> Sem r (Pred i)
  -- ^ @'dynamicArvyReceiveRequest' msg cur@ determines what the current node @cur@'s new successor should be when a token request message @msg@ was received and @cur@ holds the token. For correctness guarantees, only previously traversed nodes can be selected. This is enforced by @i@ only allowing node indices to be forwarded one way, from @'Pred' i@ to @i@ to @'Succ' i@ (which can be done with the 'forward' function).
  }

-- | A specification for how to execute a dynamic arvy algorithm. @a@ is the type of data a node needs in order to run.
data ArvySpec a i r = forall msg s r' . Show (msg Node) => ArvySpec
  { arvyBehavior :: ArvyBehavior i msg r'
  -- ^ How the algorithm should behave for certain events occuring.
  , arvyInitState :: ArvyNodeData a -> Sem r s
  , arvyRunner :: forall x . i ~ Node => (i -> Weight) -> Sem r' x -> Sem (State s ': r) x
  -- ^ How the algorithm should reinterpret the potentially node-specific effects @r'@ into non-node-specific effects @r@. For this it receives the index of the node along with its data.
  }

behaviorType :: forall (r :: [(* -> *) -> * -> *]) (msg :: * -> *) i x . x i msg r -> x i msg r
behaviorType = id

-- | A class for node indices that can be forwarded in one direction. Having this class as a constraint on types @ia@ and @ib@ is equivalent to passing a function @ia -> ib@.
class Forwardable ia ib where
  -- | Forward a node index
  forward :: ia -> ib

-- | All equivalent types can be trivially forwarded
instance Forwardable i i where
  {-# INLINE forward #-}
  forward = id

-- | A class for encoding that for a node index type @i@, there's a predecessor type @Pred i@ and a successor type @Succ i@, which can be forwarded from back to front.
class ( Forwardable (Pred i) i
      , Forwardable i (Succ i)
      , Forwardable (Pred i) (Succ i)
      ) => NodeIndex i where
  type Pred i :: *
  type Succ i :: *

-- | All types can trivially be node indices. This doesn't pose a problem since this is only used for correctness.
instance NodeIndex i where
  type Pred i = i
  type Succ i = i

type Node = Int
type NodeCount = Node
type Weight = Double

-- | The data determining the number of nodes and what data each of them should start with. @a@ is the additional algorithm-specific data each node needs. An example would be for @a@ to be @[Double]@ representing the weights to all other nodes.
data ArvyData a = ArvyData
  { arvyDataNodeCount :: NodeCount
  , arvyDataNodeData :: Node -> ArvyNodeData a
  } deriving Functor

data ArvyNodeData a = ArvyNodeData
  { arvyNodeSuccessor :: Node
  , arvyNodeWeights :: Node -> Weight
  , arvyNodeAdditional :: a
  } deriving Functor

-- | The data a single node should start with. @a@ is the additional algorithm-specific data each node needs. An example would be for @a@ to be @[Double]@ representing the weights to all other nodes.
--data ArvyNodeData a = ArvyNodeData
--  { arvyNodeDataSuccessor :: Node
--  , arvyNodeDataAdditional :: a
--  } deriving (Show, Functor)

-- | A general Arvy algorithm, unrestricted in what graphs it works on. The @a@ is the data each node needs to run. The @r@ is the effect it runs in.
newtype GeneralArvy r = GeneralArvy (forall i . NodeIndex i => ArvySpec () i r)
-- | A specific Arvy algorithm, restricted to work on the graphs generated by the @p -> Sem r (ArvyData a)@ function. The @p@ is the parameter the graph generation function takes. The @a@ is the data each node needs to run. The @r@ is the effect it runs in.
data SpecializedArvy p a r = SpecializedArvy (p -> Sem r (ArvyData a)) (forall i . NodeIndex i => ArvySpec a i r)

data LocalWeights ib (m :: * -> *) a where
  WeightTo :: Forwardable ia ib => ia -> LocalWeights ib m Weight

makeSem ''LocalWeights

{-# INLINE weightHandler #-}
weightHandler
  :: (i -> Weight)
  -> LocalWeights i m x -> Sem r x
weightHandler f = \case
  WeightTo i -> return $ f (forward i)
