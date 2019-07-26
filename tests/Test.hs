{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE OverloadedStrings #-}
module Main where

import Control.Lens
import Control.Monad
import Data.Text (Text)
import qualified Data.Text as T

import Test.Tasty
import Test.Tasty.HUnit


import Alpha
import Core
import Core.Builder
import Expander
import Module
import ModuleName
import Parser
import PartialCore
import ScopeSet
import ShortShow
import SplitCore
import Syntax.SrcLoc
import Syntax
import World

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "Expander tests" [ miniTests, moduleTests ]

miniTests :: TestTree
miniTests =
  testGroup "Mini-tests" [ expectedSuccess, expectedFailure]
  where
    expectedSuccess =
      testGroup "Expected to succeed"
      [ testCase name (testExpander input output)
      | (name, input, output) <-
        [ ( "[lambda [x] x]"
          , "[lambda [x] x]"
          , lam $ \x -> x
          )
        , ( "[lambda [x] [lambda [x] x]]"
          , "[lambda [x] [lambda [x] x]]"
          , lam $ \_ -> lam $ \y -> y
          )
        , ( "42"
          , "42"
          , sig 42
          )
        , ( "[send-signal 0]"
          , "[send-signal 0]"
          , sendSig =<< sig 0
          )
        , ( "[lambda [f] [lambda [x] [f x]]]"
          , "[lambda [f] [lambda [x] [f x]]]"
          , lam $ \f -> lam $ \x -> f `app` x
          )
        , ( "Trivial user macro"
          , "[let-syntax \n\
            \  [m [lambda [_] \n\
            \       [pure [quote [lambda [x] x]]]]] \n\
            \  m]"
          , lam $ \x -> x
          )
        , ( "Let macro"
          , "[let-syntax \n\
            \  [let1 [lambda [stx] \n\
            \          (syntax-case stx \n\
            \            [[vec [_ binder body]] \n\
            \             (syntax-case binder \n\
            \               [[vec [x e]] \n\
            \                {- [[lambda [x] body] e] -} \n\
            \                [pure [vec-syntax \n\
            \                        [[vec-syntax \n\
            \                           [[ident lambda] \n\
            \                            [vec-syntax [x] stx] \n\
            \                            body] \n\
            \                           stx] \n\
            \                         e] \n\
            \                        stx]]])])]] \n\
            \  [let1 [x [lambda [x] x]] \n\
            \    x]]"
          , (lam $ \x -> x) `app` (lam $ \x -> x)
          )
        , ( "[if #t [lambda [x] x] #f]"
          , "[if #t [lambda [x] x] #f]"
          , iF (bool True) (lam $ \x -> x) (bool False)
          )
        , ( "send a signal nobody is waiting for"
          , "[let-syntax \n\
            \  [signaling-id [lambda [_] \n\
            \                  [>>= [send-signal 0] [lambda [_] \n\
            \                  [pure [quote [lambda [x] x]]]]]]] \n\
            \    [signaling-id]]"
          , lam $ \x -> x
          )
        ]
      ]
    expectedFailure =
      testGroup "Expected to fail"
      [ testCase (show input) (testExpansionFails input predicate)
      | (input, predicate) <-
        [ ( "x"
          , \case
              Unknown (Stx _ _ "x") -> True
              _ -> False
          )
        , ("[let-syntax \
           \  [m [lambda [_] \
           \       [pure [quote [lambda [x] x]]]]] \
           \  anyRandomWord]"
           , \case
               Unknown (Stx _ _ "anyRandomWord") -> True
               _ -> False
           )
        , ("[lambda [x] [let-syntax [m [lambda [_] x]] x]]"
          , \case
              Unknown (Stx _ _ "x") -> True
              _ -> False
          )
        , ("[let-syntax [m [lambda [x] [m x]]] m]"
          , \case
              Unknown (Stx _ loc "m") ->
                -- Make sure it's the use site in the macro body that
                -- throws the error
                view (srcLocStart . srcPosCol) loc == 29
              _ -> False
          )
        ]
      ]

moduleTests :: TestTree
moduleTests = testGroup "Module tests" [ shouldWork ]
  where
    shouldWork =
      testGroup "Expected to succeed"
      [ testCase fn (testFile fn p)
      | (fn, p) <-
        [ ( "examples/small.sm"
          , \m -> isEmpty (view moduleBody m)
          )
        , ( "examples/id-compare.sm"
          , \m->
              view moduleBody m &
              filter (\case {(Example _) -> True; _ -> False}) &
              \case
                [Example e1, Example e2] -> do
                  assertAlphaEq "first example" e1 (Core (CoreBool True))
                  assertAlphaEq "second example" e2 (Core (CoreBool False))
                _ -> assertFailure "Expected two examples"
          )
        ]
      ]

    isEmpty [] = return ()
    isEmpty _ = assertFailure "Expected empty, got non-empty"



testExpander :: Text -> IO Core -> Assertion
testExpander input spec = do
  output <- spec
  case readExpr "<test suite>" input of
    Left err -> assertFailure . T.unpack $ err
    Right expr -> do
      ctx <- mkInitContext (KernelName kernelName)
      c <- flip execExpand ctx $ do
             initializeKernel
             initializeLanguage (Stx ScopeSet.empty testLoc (KernelName kernelName))
             addRootScope expr >>= addModuleScope >>= expandExpr
      case c of
        Left err -> assertFailure . T.unpack . expansionErrText $ err
        Right expanded ->
          case runPartialCore $ unsplit expanded of
            Nothing -> assertFailure "Incomplete expansion"
            Just done -> assertAlphaEq (T.unpack input) output done
  where testLoc = SrcLoc "test contents" (SrcPos 0 0) (SrcPos 0 0)

testExpansionFails :: Text -> (ExpansionErr -> Bool) -> Assertion
testExpansionFails input okp =
  case readExpr "<test suite>" input of
    Left err -> assertFailure . T.unpack $ err
    Right expr -> do
      ctx <- mkInitContext (KernelName kernelName)
      c <- flip execExpand ctx $ do
             initializeKernel
             initializeLanguage (Stx ScopeSet.empty testLoc (KernelName kernelName))
             expandExpr =<< addModuleScope =<< addRootScope expr

      case c of
        Left err
          | okp err -> return ()
          | otherwise ->
            assertFailure $ "An error was expected but not this one: " ++ show err
        Right expanded ->
          case runPartialCore $ unsplit expanded of
            Nothing -> assertFailure "Incomplete expansion"
            Just _ -> assertFailure "Error expected, but expansion succeeded"
  where testLoc = SrcLoc "test contents" (SrcPos 0 0) (SrcPos 0 0)


testFile :: FilePath -> (Module [] (Decl Core) -> Assertion) -> Assertion
testFile f p = do
  mn <- moduleNameFromPath f
  ctx <- mkInitContext mn
  void $ execExpand initializeKernel ctx
  execExpand (visit mn >> view expanderWorld <$> getState) ctx >>=
    \case
      Left err -> assertFailure (T.unpack (expansionErrText err))
      Right w ->
        view (worldModules . at mn) w &
        \case
          Nothing ->
            assertFailure "No module found"
          Just (KernelModule _) ->
            assertFailure "Expected user module, got kernel"
          Just (Expanded m) ->
            p m



assertAlphaEq :: (AlphaEq a, ShortShow a) => String -> a -> a -> Assertion
assertAlphaEq preface expected actual =
  unless (alphaEq actual expected) (assertFailure msg)
 where msg = (if null preface then "" else preface ++ "\n") ++
             "expected: " ++ shortShow expected ++ "\n but got: " ++ shortShow actual
