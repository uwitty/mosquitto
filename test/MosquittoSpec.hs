{-# OPTIONS_GHC  -fno-warn-orphans #-}

module MosquittoSpec (main, spec) where

import Network.Mosquitto

import Test.Hspec
import Control.Monad.Trans
import Control.Concurrent(threadDelay)
import qualified Data.ByteString as BS

main :: IO ()
main = hspec spec

spec :: Spec
spec = helperSpec >> contextSpec >> mosquittoSpec

helperSpec :: Spec
helperSpec = do
    describe "initialize" $ do
      it "initializes lib" $ do
        initialized <- liftIO $ withInit (return True)
        initialized `shouldBe` True

      it "creates new mosquitto object" $ do
        created <- liftIO $ withInit . withMosq Nothing $ \_mosq -> return True
        created `shouldBe` True

    describe "connect" $ do
      it "connects to broker in localhost" $ do
        connected <- liftIO $ withInit . withMosq Nothing $ \mosq -> withConnect mosq "localhost" 1883 60 (return True)
        connected `shouldBe` True

      it "connects to broker and gets ack from localhost" $ do
        connected <- liftIO $ withInit . withMosq Nothing $ \mosq -> withConnack mosq "localhost" 1883 60 3000 (return True)
        connected `shouldBe` True

contextSpec :: Spec
contextSpec = do
    describe "test" $ do
      it "connects to broker in localhost" $ do
        connected <- liftIO $ withInit . withMosq Nothing $ \mosq -> do
          ctx <- newMosqContext mosq
          result <- connect ctx "localhost" 1883 500
          freeMosqContext ctx
          return result
        connected `shouldBe` 0

mosquittoSpec :: Spec
mosquittoSpec = do
    describe "getNextEvents" $ do
      it "connects to broker in localhost" $ do
        events <- liftIO $ withInit . withMosqContext Nothing $ \ctx -> do
          _ <- connect ctx "localhost" 1883 500
          _ <- subscribe ctx "test/test" 2
          _ <- publish ctx "test/test" (BS.pack [84, 84, 84]) 2 False
          loop ctx 10 []
        events `shouldSatisfy` (\x -> (length x) > 0)
  where
    loop :: MosqContext -> Int -> [MosqEvent] -> IO [MosqEvent]
    loop ctx count events = do
      if count == 0
        then return events
        else do
             (_, es) <- getNextEvents ctx 500
             threadDelay 100000
             loop ctx (count - 1) (events ++ es)
