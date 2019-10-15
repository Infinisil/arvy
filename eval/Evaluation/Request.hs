{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE DeriveFunctor     #-}
{-# LANGUAGE OverloadedStrings #-}
module Evaluation.Request where

import Data.Array.Unboxed
import Prelude
import Conduit
import qualified Data.Conduit.Combinators as C
import Evaluation.Types
import Polysemy
import Data.Time
import Data.MonoTraversable
import Data.NonNull
import Arvy.Algorithm
import Data.Sequences
import Arvy.Log

traceRequests :: forall r x . ( LogMember r, Member (Lift IO) r ) => ConduitT x x (Sem r) ()
traceRequests = do
  time <- lift $ sendM getCurrentTime
  go 0 time where
  go :: Int -> UTCTime -> ConduitT x x (Sem r) ()
  go k prev = await >>= \case
    Nothing -> lift $ lgInfo "Done"
    Just event -> do
      let k' = k + 1
      time <- lift $ sendM getCurrentTime
      if time `diffUTCTime` prev > 1
        then do
          lift $ lgInfo $ "[" <> tshow k' <> "]"
          yield event
          go k' time
        else do
          yield event
          go k' prev


hopCount :: (Monad m, MonoFoldable seq) => ConduitT (NonNull seq) Int m ()
hopCount = C.map (subtract 1 . olength)



requestDists :: (Monad m, Element seq ~ Node, IsSequence seq) => Env -> ConduitT (NonNull seq) Double m ()
requestDists Env { envWeights = weights } = C.map (\s ->
                                                     sum $ zipWith (\from to ->
                                                                      weights ! (from, to))
                                                     (otoList (Data.NonNull.init s))
                                                     (otoList (Data.NonNull.tail s)))

requestRatios :: (Monad m, Element seq ~ Node, IsSequence seq) => Env -> ConduitT (NonNull seq) Double m ()
requestRatios Env { envWeights = weights } = C.filter ((>= 2) . olength) .| C.map (\s ->
                                                     (/ weights ! ( Data.NonNull.head s
                                                                  , Data.NonNull.last s))
                                                     $ sum $ zipWith (\from to ->
                                                                      weights ! (from, to))
                                                     (otoList (Data.NonNull.init s))
                                                     (otoList (Data.NonNull.tail s)))

--requestRatio :: Monad m => Env -> ConduitT ArvyEvent Double m ()
--requestRatio Env { envWeights = weights } = collectRequests (\edge -> Sum (weights ! edge)) -- Collect requests by measuring the length of the edges they take
--  .| C.map (\(Request a b (Sum path)) -> if a == b then 1 else path / weights ! (a, b)) -- Calculate the ratio between request edge lengths and graph edge length
