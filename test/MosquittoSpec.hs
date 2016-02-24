{-# OPTIONS_GHC  -fno-warn-orphans #-}

module MosquittoSpec (main, spec) where

import Network.Mosquitto

import Test.Hspec
import Control.Concurrent(threadDelay)
import qualified Data.ByteString as BS

main :: IO ()
main = hspec spec

spec :: Spec
spec = helperSpec >> mosquittoSpec

helperSpec :: Spec
helperSpec = do
    describe "initialize" $ do
      it "initializes lib" $ do
        initialized <- withInit (return True)
        initialized `shouldBe` True

    describe "connect" $ do
      it "connects to broker in localhost" $ do
        connected <- withInit . withMosquitto Nothing $ \m -> withConnect m "localhost" 1883 60 (return True)
        connected `shouldBe` True
 
    describe "create Mosquitto object" $ do
      it "initializes/cleanups" $ do
        initializeMosquittoLib
        newMosquitto Nothing >>= destroyMosquitto
        cleanupMosquittoLib

mosquittoSpec :: Spec
mosquittoSpec = do
    describe "getNextEvents" $ do
      it "connects to broker in localhost" $ do
        events <- withInit . withMosquitto Nothing $ \m -> do
          _ <- connect m "localhost" 1883 500
          _ <- subscribe m "test/test" 2
          (_, mid) <- publish m "test/test" (BS.pack [84, 84, 84]) 2 False
          mid `shouldSatisfy` (> 0)
          es <- loop m 10 []
          _ <- disconnect m
          loop m 3 es
        events `shouldSatisfy` (\x -> (length x) > 0)
  where
    loop :: Mosquitto -> Int -> [Event] -> IO [Event]
    loop m count events = do
      if count == 0
        then return events
        else do
             (_, es) <- getNextEvents m 500
             threadDelay 100000
             loop m (count - 1) (events ++ es)
