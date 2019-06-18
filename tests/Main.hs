{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeApplications      #-}

module Main where

import           Arvy.Tree
import           Arvy.Utils
import           Arvy.Weights
import           Control.DeepSeq
import           Control.Exception
import           Control.Monad.ST
import           Data.Array.IO
import           Data.Array.ST
import           Data.Array.Unboxed
import qualified Data.Tree          as T
import           Polysemy
import           Polysemy.Random
import           System.Random      (mkStdGen)
import           Test.Hspec

withSeed :: Int -> Sem '[Random] a -> a
withSeed seed = snd . run . runRandom (mkStdGen seed)

main :: IO ()
main = hspec $ do
  describe "Arvy.Weights.shortestPathWeights" $ do
    it "calculates the transitive shortest paths" $
      shortestPathWeights (0 * 1 + 1 * 2) ! (0, 2) `shouldBe` 2

    it "returns infinity for paths that don't exist" $
      shortestPathWeights (0 + 1) ! (0, 1) `shouldBe` infinity

    it "finds the shorter path of multiple" $
      shortestPathWeights (0 * 1 + 1 * 2 + 2 * 3 + 0 * 4 + 4 * 3) ! (0, 3)
        `shouldBe` 2

    it "throws an error for vertices holes" $
      evaluate (shortestPathWeights (0 * 2)) `shouldThrow` anyErrorCall

    it "assigns 0 to paths from nodes to themselves" $
      shortestPathWeights 0 ! (0, 0) `shouldBe` 0

    it "correctly assigns weights to a 4-node ring" $
      ringWeights 4 `shouldBe` listArray ((0, 0), (3, 3))
        [ 0, 1, 2, 1
        , 1, 0, 1, 2
        , 2, 1, 0, 1
        , 1, 2, 1, 0
        ]

  describe "Arvy.Tree.treeStructure" $ do
    it "finds the structure with a single node" $
      treeStructure (listArray (0, 0) [Nothing]) `shouldBe` T.Node 0 []

    it "finds the structure with every node pointing to the root" $
      treeStructure (listArray (0, 3) (Nothing : repeat (Just 0))) `shouldBe` T.Node 0 [T.Node 1 [], T.Node 2 [], T.Node 3 []]

    it "finds the structure with indirect pointers" $
      treeStructure (listArray (0, 3) (Nothing : map Just [0..])) `shouldBe` T.Node 0 [T.Node 1 [T.Node 2 [T.Node 3 []]]]

    it "finds the structure of a binary tree" $
      treeStructure (listArray (0, 6) [Nothing, Just 0, Just 1, Just 1, Just 0, Just 4, Just 4])
        `shouldBe` T.Node 0 [T.Node 1 [T.Node 2 [], T.Node 3 []], T.Node 4 [T.Node 5 [], T.Node 6 []]]

    it "errors when there's no root" $
      evaluate (force (treeStructure (listArray (0, 3) [Just 1, Just 0, Just 2, Just 1])))
        `shouldThrow` errorCall "Tree has no root"

    it "errors when there's multiple roots" $
      evaluate (force (treeStructure (listArray (0, 3) [Just 1, Nothing, Nothing, Just 1])))
        `shouldThrow` errorCall "Tree has multiple roots at both node 1 and 2"

    it "doesn't error on lost nodes" $
      treeStructure (listArray (0, 3) [Nothing, Just 0, Just 3, Just 2]) `shouldBe` T.Node 0 [T.Node 1 []]

  testWithFrozen

testWithFrozen :: Spec
testWithFrozen = describe "Arvy.Utils.withFrozen" $ do
  it "doesn't evaluate results lazily" $
    testWhnfIO `shouldReturn` 0

  it "fully evaluates results to normal form" $
    testNfIO `shouldReturn` [0]

  it "works with strict ST" $
    runST testST `shouldBe` [0]

  where

    testWhnfIO :: IO Int
    testWhnfIO = runM $ do
      arr <- sendM (newArray (0, 0) 0 :: IO (IOArray Int Int))
      res <- withFrozen @Array @IO arr $ \f a ->
        return $ f (a ! 0)
      sendM @IO $ writeArray arr 0 1
      return res


    testNfIO :: IO [Int]
    testNfIO = runM $ do
      arr <- sendM (newArray (0, 0) 0 :: IO (IOArray Int Int))
      res <- withFrozen @Array @IO arr $ \f a ->
        return [f (a ! 0)]
      sendM @IO $ writeArray arr 0 1
      return res

    testST :: forall s . ST s [Int]
    testST = runM $ do
      arr <- sendM (newArray (0, 0) 0 :: ST s (STArray s Int Int))
      res <- withFrozen @Array @(ST s) arr $ \f a ->
        return [f (a ! 0)]
      sendM @(ST s) $ writeArray arr 0 1
      return res
