{-# LANGUAGE AllowAmbiguousTypes       #-}
{-# LANGUAGE BlockArguments            #-}
{-# LANGUAGE DataKinds                 #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE GADTs                     #-}
{-# LANGUAGE KindSignatures            #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE NamedFieldPuns            #-}
{-# LANGUAGE RankNTypes                #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE TypeApplications          #-}
{-# LANGUAGE TypeOperators             #-}

module Arvy
  ( module Arvy.Algorithm.Arrow
  , module Arvy.Algorithm.Ivy
  , module Arvy.Algorithm.ConstantRing
  ) where

import           Arvy.Algorithm.Arrow
import           Arvy.Algorithm.ConstantRing
import           Arvy.Algorithm.Ivy

import           Algebra.Graph.AdjacencyIntMap hiding (tree)
import           Data.Array.IArray
import           Data.Array.IO                 (IOArray)
import           Data.Monoid
import           Polysemy
import           Polysemy.Output
import           Polysemy.Random
import           Polysemy.Trace

import           Arvy.Algorithm
import           Arvy.Algorithm.Arrow
import           Arvy.Algorithm.Ivy
import           Arvy.Requests
import           Arvy.Tree
import           Arvy.Weights

traceMessages :: forall i r a . (Member Trace r, Member (Output (i, i)) r, Show i) => Sem r a -> Sem r a
traceMessages = intercept @(Output (i, i)) $ \case
  Output (from, to) -> do
    trace $ show from ++ " -> " ++ show to
    output (from, to)

-- | Measures distances
measureDistances :: (Ix i, IArray arr n, Num n) => arr i n -> Sem (Output i ': r) a -> Sem r (Sum n, a)
measureDistances weights = runFoldMapOutput (Sum . (weights !))
