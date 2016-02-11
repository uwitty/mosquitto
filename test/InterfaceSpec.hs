{-# OPTIONS_GHC  -fno-warn-orphans #-}

module InterfaceSpec (main, spec) where

import Network.Mosquitto.C.Interface
import Network.Mosquitto.C.Types(Mosq, errNoConn)

import Test.Hspec
import Data.IORef
import Control.Concurrent
import Control.Monad
import Foreign.Ptr(Ptr, plusPtr, nullPtr, freeHaskellFunPtr)
import Foreign.C.String(withCStringLen)
import Foreign.C.Types(CInt(..))
import Foreign.Storable(sizeOf, peek, peekElemOff)
import Foreign.Marshal.Alloc(mallocBytes, free)

main :: IO ()
main = hspec spec

spec :: Spec
spec = versionSpec >> interfaceSpec >> interfaceErrorSpec

versionSpec :: Spec
versionSpec = do
    describe "mosquitto version" $
      it "resturns version" $ do
        version <- c_mosquitto_lib_version nullPtr nullPtr nullPtr
        version `shouldSatisfy` (\v -> v > 0)
        p <- mallocBytes (sizeOf dummy) :: IO (Ptr CInt)
        _ <- c_mosquitto_lib_version p (p `plusPtr` (sizeOf dummy)) (p `plusPtr` (2 * sizeOf dummy))
        major    <- peek p
        minor    <- peekElemOff p 1
        revision <- peekElemOff p 2
        free p
        (major * 1000000 + minor * 1000 + revision) `shouldBe` version
  where
    dummy :: CInt
    dummy = 0

data CallbackResults = CallbackResults { connected    :: Bool
                                       , subscribed   :: Bool
                                       , published    :: Bool
                                       , disconnected :: Bool
                                       }

interfaceSpec :: Spec
interfaceSpec = do
    describe "mosquitto C functions" $ do
      it "calls lib mosquitto c functions" $ example $ do
        -- wrap callbacks
        results <- newIORef $ CallbackResults False False False False
        connectCallbackC    <- wrapOnConnectCallback (connectCallback results)
        subscribeCallbackC  <- wrapOnSubscribeCallback (subscribeCallback results)
        publishCallbackC    <- wrapOnPublishCallback (publishCallback results)
        disconnectCallbackC <- wrapOnDisconnectCallback (disconnectCallback results)

        -- initialize mosquitto
        c_mosquitto_lib_init >>= (`shouldBe` 0)
        mosq <- c_mosquitto_new nullPtr 1 nullPtr
        mosq `shouldSatisfy` (/= nullPtr)
        c_mosquitto_connect_callback_set mosq connectCallbackC
        c_mosquitto_subscribe_callback_set mosq subscribeCallbackC
        c_mosquitto_publish_callback_set mosq publishCallbackC
        c_mosquitto_disconnect_callback_set mosq disconnectCallbackC

        -- connect to broker
        (withCStringLen "localhost" $
          \(hostnameC, _len) -> c_mosquitto_connect mosq hostnameC 1883 500) >>= (`shouldBe` 0)
        (withCStringLen "test/test" $ \(patternC, _len) ->
          c_mosquitto_subscribe mosq nullPtr patternC 2) >>= (`shouldBe` 0)
        (withCStringLen "test/test" $ \(topicNameC, _len) ->
          c_mosquitto_publish mosq nullPtr topicNameC 9 topicNameC 2 0) >>= (`shouldBe` 0)

        -- mosquitto_loop
        replicateM_ 5 $ c_mosquitto_loop mosq 10 1 >>= (`shouldBe` 0) >> threadDelay 100000
        -- verify
        fmap connected    (readIORef results) >>= (`shouldBe` True)
        fmap subscribed   (readIORef results) >>= (`shouldBe` True)
        fmap published    (readIORef results) >>= (`shouldBe` True)

        -- disconnect
        c_mosquitto_disconnect mosq >>= (`shouldBe` 0)
        replicateM_ 3 $ c_mosquitto_loop mosq 10 1 >>= (`shouldSatisfy` (\x -> x == 0 || x == errNoConn)) >> threadDelay 10000
        c_mosquitto_loop mosq 10 1 >>= (`shouldBe` errNoConn)
        fmap disconnected (readIORef results) >>= (`shouldBe` True)

        -- cleanup mosquitto
        c_mosquitto_destroy mosq
        c_mosquitto_lib_cleanup >>= (`shouldBe` 0)

        -- free wrapped functions
        freeHaskellFunPtr disconnectCallbackC
        freeHaskellFunPtr publishCallbackC
        freeHaskellFunPtr subscribeCallbackC
        freeHaskellFunPtr connectCallbackC
  where
    connectCallback :: IORef CallbackResults -> Mosq -> Ptr () -> CInt -> IO ()
    connectCallback ref _mosq _userdata result = do
      if result == 0
        then do results <- readIORef ref
                writeIORef ref $ results {connected = True}
        else return ()

    subscribeCallback :: IORef CallbackResults -> Mosq -> Ptr () -> CInt -> CInt -> Ptr CInt -> IO ()
    subscribeCallback ref _mosq _userdata _mid _qosCount _grandtedQos = do
      results <- readIORef ref
      writeIORef ref $ results {subscribed = True}

    publishCallback :: IORef CallbackResults -> Mosq -> Ptr () -> CInt -> IO ()
    publishCallback ref _mosq _userdata _mid = do
      results <- readIORef ref
      writeIORef ref $ results {published = True}

    disconnectCallback :: IORef CallbackResults -> Mosq -> Ptr () -> CInt -> IO ()
    disconnectCallback ref _mosq _userdata _mid = do
      results <- readIORef ref
      writeIORef ref $ results {disconnected = True}

interfaceErrorSpec :: Spec
interfaceErrorSpec = do
    describe "mosquitto C functions - error case" $ do
      it "gets errNoConn errors" $ do
        c_mosquitto_lib_init >>= (`shouldBe` 0)
        mosq <- c_mosquitto_new nullPtr 1 nullPtr
        mosq `shouldSatisfy` (/= nullPtr)
        (withCStringLen "test/test" $ \(patternC, _len) ->
          c_mosquitto_subscribe mosq nullPtr patternC 2) >>= (`shouldBe` errNoConn)
        c_mosquitto_disconnect mosq >>= (`shouldBe` errNoConn)
        c_mosquitto_strerror errNoConn >>= (`shouldSatisfy` (/= nullPtr))
        c_mosquitto_destroy mosq
        c_mosquitto_lib_cleanup >>= (`shouldBe` 0)

