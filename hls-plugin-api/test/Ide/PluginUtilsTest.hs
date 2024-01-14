{-# LANGUAGE OverloadedLabels  #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications  #-}

module Ide.PluginUtilsTest
    ( tests
    ) where

import qualified Data.Aeson                  as A
import qualified Data.Aeson.Types            as A
import           Data.Char                   (isPrint)
import           Data.Function               ((&))
import qualified Data.Set                    as Set
import qualified Data.Text                   as T
import           Ide.Plugin.Properties       (KeyNamePath (..),
                                              definePropertiesProperty,
                                              defineStringProperty,
                                              emptyProperties, toDefaultJSON,
                                              toVSCodeExtensionSchema,
                                              usePropertyByPath,
                                              usePropertyByPathEither)
import qualified Ide.Plugin.RangeMap         as RangeMap
import           Ide.PluginUtils             (extractTextInRange,
                                              positionInRange, unescape)
import           Language.LSP.Protocol.Types (Position (..), Range (Range),
                                              UInt, isSubrangeOf)
import           Test.Tasty
import           Test.Tasty.HUnit
import           Test.Tasty.QuickCheck

tests :: TestTree
tests = testGroup "PluginUtils"
    [ unescapeTest
    , extractTextInRangeTest
    , localOption (QuickCheckMaxSize 10000) $
        testProperty "RangeMap-List filtering identical" $
          prop_rangemapListEq @Int
    , propertyTest
    ]

unescapeTest :: TestTree
unescapeTest = testGroup "unescape"
    [ testCase "no double quote" $
        unescape "hello世界" @?= "hello世界"
    , testCase "whole string quoted" $
        unescape "\"hello\\19990\\30028\"" @?= "\"hello世界\""
    , testCase "text before quotes should not be unescaped" $
        unescape "\\19990a\"hello\\30028\"" @?= "\\19990a\"hello界\""
    , testCase "some text after quotes" $
        unescape "\"hello\\19990\\30028\"abc" @?= "\"hello世界\"abc"
    , testCase "many pairs of quote" $
        unescape "oo\"hello\\19990\\30028\"abc\"\1087\1088\1080\1074\1077\1090\"hh" @?= "oo\"hello世界\"abc\"привет\"hh"
    , testCase "double quote itself should not be unescaped" $
        unescape "\"\\\"\\19990o\"" @?= "\"\\\"世o\""
    , testCase "control characters should not be escaped" $
        unescape "\"\\n\\t\"" @?= "\"\\n\\t\""
    ]

extractTextInRangeTest :: TestTree
extractTextInRangeTest = testGroup "extractTextInRange"
    [ testCase "inline range" $
        extractTextInRange
            ( Range (Position 0 3) (Position 3 5) )
            src
        @?= T.intercalate "\n"
                [ "ule Main where"
                , ""
                , "main :: IO ()"
                , "main "
                ]
    , testCase "inline range with empty content" $
        extractTextInRange
            ( Range (Position 0 0) (Position 0 1) )
            emptySrc
        @?= ""
    , testCase "multiline range with empty content" $
        extractTextInRange
            ( Range (Position 0 0) (Position 1 0) )
            emptySrc
        @?= "\n"
    , testCase "multiline range" $
        extractTextInRange
            ( Range (Position 1 0) (Position 4 0) )
            src
        @?= T.unlines
                [ ""
                , "main :: IO ()"
                , "main = do"
                ]
    , testCase "multiline range with end pos at the line below the last line" $
        extractTextInRange
            ( Range (Position 2 0) (Position 5 0) )
            src
        @?= T.unlines
                [ "main :: IO ()"
                , "main = do"
                , "    putStrLn \"hello, world\""
                ]
    ]
    where
        src = T.unlines
                [ "module Main where"
                , ""
                , "main :: IO ()"
                , "main = do"
                , "    putStrLn \"hello, world\""
                ]
        emptySrc = "\n"

genRange :: Gen Range
genRange = oneof [ genRangeInline, genRangeMultiline ]

genRangeInline :: Gen Range
genRangeInline = do
  x1 <- genPosition
  delta <- genRangeLength
  let x2 = x1 { _character = _character x1 + delta }
  pure $ Range x1 x2
  where
    genRangeLength :: Gen UInt
    genRangeLength = fromInteger <$> chooseInteger (5, 50)

genRangeMultiline :: Gen Range
genRangeMultiline = do
  x1 <- genPosition
  let heightDelta = 1
  secondX <- genSecond
  let x2 = x1 { _line = _line x1 + heightDelta
              , _character = secondX
              }
  pure $ Range x1 x2
  where
    genSecond :: Gen UInt
    genSecond = fromInteger <$> chooseInteger (0, 10)

genPosition :: Gen Position
genPosition = Position
  <$> (fromInteger <$> chooseInteger (0, 1000))
  <*> (fromInteger <$> chooseInteger (0, 150))

instance Arbitrary Range where
  arbitrary = genRange

prop_rangemapListEq :: (Show a, Eq a, Ord a) => Range -> [(Range, a)] -> Property
prop_rangemapListEq r xs =
  let filteredList = (map snd . filter (isSubrangeOf r . fst)) xs
      filteredRangeMap = RangeMap.filterByRange r (RangeMap.fromList' xs)
   in classify (null filteredList) "no matches" $
      cover 5 (length filteredList == 1) "1 match" $
      cover 2 (length filteredList > 1) ">1 matches" $
      Set.fromList filteredList === Set.fromList filteredRangeMap


propertyTest :: TestTree
propertyTest = testGroup "property api tests" [
    testCase "property toVSCodeExtensionSchema" $ do
        let expect = "[(\"top.baz\",Object (fromList [(\"default\",String \"baz\"),(\"markdownDescription\",String \"baz\"),(\"scope\",String \"resource\"),(\"type\",String \"string\")])),(\"top.parent.foo\",Object (fromList [(\"default\",String \"foo\"),(\"markdownDescription\",String \"foo\"),(\"scope\",String \"resource\"),(\"type\",String \"string\")]))]"
        let result = toVSCodeExtensionSchema "top." nestedPropertiesExample
        show result @?= expect
    , testCase "property toDefaultJSON" $ do
        let expect = "[(\"baz\",String \"baz\"),(\"parent\",Object (fromList [(\"foo\",String \"foo\")]))]"
        let result = toDefaultJSON nestedPropertiesExample
        show result @?= expect
    , testCase "parsePropertyPath single key path" $ do
        let obj = A.object (toDefaultJSON nestedPropertiesExample)
        let (Right key1) = A.parseEither (A.withObject "test parsePropertyPath" $ \o -> do
                let (Right key1) = usePropertyByPathEither examplePath1 nestedPropertiesExample o
                return key1) obj
        key1 @?= "baz"
    , testCase "parsePropertyPath two key path" $ do
        let obj = A.object (toDefaultJSON nestedPropertiesExample)
        let (Right key1) = A.parseEither (A.withObject "test parsePropertyPath" $ \o -> do
                let (Right key1) = usePropertyByPathEither examplePath2 nestedPropertiesExample o
                return key1) obj
        key1 @?= "foo"
    , testCase "parsePropertyPath two key path default" $ do
        let obj = A.object []
        let (Right key1) = A.parseEither (A.withObject "test parsePropertyPath" $ \o -> do
                let key1 = usePropertyByPath examplePath2 nestedPropertiesExample o
                return key1) obj
        key1 @?= "foo"
    , testCase "parsePropertyPath two key path not default" $ do
        let obj = A.object (toDefaultJSON nestedPropertiesExample2)
        let (Right key1) = A.parseEither (A.withObject "test parsePropertyPath" $ \o -> do
                let (Right key1) = usePropertyByPathEither examplePath2 nestedPropertiesExample o
                return key1) obj
        key1 @?= "xxx"
    ]
    where
    nestedPropertiesExample = emptyProperties
        & definePropertiesProperty #parent "parent" (emptyProperties & defineStringProperty #foo "foo" "foo")
        & defineStringProperty #baz "baz" "baz"

    nestedPropertiesExample2 = emptyProperties
        & definePropertiesProperty #parent "parent" (emptyProperties & defineStringProperty #foo "foo" "xxx")
        & defineStringProperty #baz "baz" "baz"

    examplePath1 = SingleKey #baz
    examplePath2 = ConsKeysPath #parent (SingleKey #foo)


sieve = sx [2..]
  where
    sx (p:xs) = p : sx [x| x <- xs, x `mod` p > 0]

main = do
  print (take 10000 sieve)
