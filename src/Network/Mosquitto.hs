module Network.Mosquitto where

import Network.Mosquitto.C.Interface
import Network.Mosquitto.C.Types

import Control.Monad.IO.Class
import Data.IORef
import Data.Maybe(isJust, fromJust)
import qualified Data.ByteString as BS
import Control.Concurrent
import Control.Exception(bracket, bracket_, throwIO, AssertionFailed(..))
import Foreign.Ptr(Ptr, FunPtr, nullPtr, castFunPtr, freeHaskellFunPtr)
import Foreign.Storable(peek)
import Foreign.C.String(withCStringLen, peekCString)
import Foreign.C.Types(CInt(..))
import Foreign.Marshal.Array(peekArray)

data MosqEvent = Message 
                     { messageID      :: !Int
                     , messageTopic   :: !String
                     , messagePayload :: !BS.ByteString
                     , messageQos     :: !Int
                     , messageRetain  :: !Bool
                     }
               | ConnectResult {connectResultCode :: !Int}
  deriving Show

data MosqContext = MosqContext {contextMosq :: Mosq, contextEvents :: IORef [MosqEvent], contextCallbacks :: [FunPtr ()]}

type ConnectCallback = (Mosq -> Int -> IO ())

newMosqContext :: Mosq -> IO MosqContext
newMosqContext mosq = do
    events <- newIORef ([] :: [MosqEvent])
    connectCallbackC <- wrapOnConnectCallback (connectCallback events)
    c_mosquitto_connect_callback_set mosq connectCallbackC
    messageCallbackC <- wrapOnMessageCallback (messageCallback events)
    c_mosquitto_message_callback_set mosq messageCallbackC
    return MosqContext { contextMosq = mosq
                       , contextEvents = events
                       , contextCallbacks = [ castFunPtr connectCallbackC
                                            , castFunPtr messageCallbackC]
                       }
  where
    connectCallback :: IORef [MosqEvent] -> Mosq -> Ptr () -> CInt -> IO ()
    connectCallback events _mosq _ result = do
      if result == 0
        then pushEvent events (ConnectResult (fromIntegral result))
        else return ()
    messageCallback :: IORef [MosqEvent] -> Mosq -> Ptr () -> Ptr MessageC -> IO ()
    messageCallback events _mosq _ messageC = do
        msg   <- peek messageC
        topic <- peekCString (messageCTopic msg)
        payload <- peekArray (fromIntegral $ messageCPayloadLen msg) (messageCPayload msg)
        pushEvent events $ Message (fromIntegral $ messageCID msg)
                                   topic
                                   (BS.pack payload)
                                   (fromIntegral $ messageCQos msg)
                                   (messageCRetain msg)

freeMosqContext :: MosqContext -> IO ()
freeMosqContext context = mapM_ freeHaskellFunPtr (contextCallbacks context)

--loop :: MosqContext -> Int -> Int -> IO Int
--loop context timeout maxPackets = do
--    c_mosquitto_loop (contextMosq context) (fromIntegral timeout) (fromIntegral maxPackets) >>= return . fromIntegral

connect :: MosqContext -> String -> Int -> Int -> IO Int
connect context hostname port keepAlive =
    fmap fromIntegral . withCStringLen hostname $ \(hostnameC, _len) ->
        c_mosquitto_connect (contextMosq context) hostnameC (fromIntegral port) (fromIntegral keepAlive)

getNextEvents :: MosqContext -> Int -> IO (Int, [MosqEvent])
getNextEvents context timeout = do
    result <- fmap fromIntegral . liftIO $ c_mosquitto_loop (contextMosq context) (fromIntegral timeout) 1
    if result == 0
      then do events <- liftIO . fmap reverse $ readIORef (contextEvents context)
              writeIORef (contextEvents context) []
              return (result, events)
      else return (result, [])

subscribe :: MosqContext -> String -> Int -> IO Int
subscribe context topicName qos = do
    fmap fromIntegral . withCStringLen topicName $ \(topicNameC, _len) ->
      c_mosquitto_subscribe (contextMosq context) nullPtr topicNameC (fromIntegral qos)

publish :: MosqContext -> String -> BS.ByteString -> Int -> Bool -> IO Int
publish context topicName payload qos retain = do
    fmap fromIntegral $
         withCStringLen topicName $ \(topicNameC, _) ->
         BS.useAsCString payload $ \payloadC -> do
           c_mosquitto_publish (contextMosq context) nullPtr topicNameC (fromIntegral (BS.length payload)) payloadC (fromIntegral qos) (if retain then 1 else 0)

-- util

pushEvent :: IORef [MosqEvent] -> MosqEvent -> IO ()
pushEvent ref e = do
    es <- readIORef ref
    writeIORef ref (e:es)

-- Helper

withInit :: IO a -> IO a
withInit =
    bracket_ initMosquitto c_mosquitto_lib_cleanup
  where
    initMosquitto :: IO ()
    initMosquitto = do result <- c_mosquitto_lib_init
                       if result == 0
                         then return ()
                         else throwIO $ AssertionFailed "failed to initialize mosquiotto"

withMosq :: Maybe String -> (Mosq -> IO a) -> IO a
withMosq (Just clientId) action = withCStringLen clientId $ \(idC, _len) -> 
                                    bracket (c_mosquitto_new idC 1 nullPtr) (c_mosquitto_destroy) action
withMosq Nothing         action = bracket (c_mosquitto_new nullPtr 1 nullPtr) (c_mosquitto_destroy) action

withMosqContext :: Maybe String -> (MosqContext -> IO a) -> IO a
withMosqContext maybeId action
    | isJust maybeId = withCStringLen (fromJust maybeId) $ \(idC, _) ->
                         bracket (c_mosquitto_new idC 1 nullPtr >>= newMosqContext) cleanup action
    | otherwise      = bracket (c_mosquitto_new nullPtr 1 nullPtr >>= newMosqContext) cleanup action
  where
    cleanup :: MosqContext -> IO ()
    cleanup ctx = do
      freeMosqContext ctx
      c_mosquitto_destroy (contextMosq ctx)

withConnect :: Mosq -> String -> Int -> Int -> IO a -> IO a
withConnect mosq hostname port keepAlive = bracket_ connectI disconnect
  where
    connectI :: IO ()
    connectI = do
      result <- withCStringLen hostname $ \(hostnameC, _len) ->
        c_mosquitto_connect mosq hostnameC (fromIntegral port) (fromIntegral keepAlive)
      if result == (CInt 0)
        then return ()
        else throwIO $ AssertionFailed $ "failed to connect: " ++ (show result)
    disconnect :: IO ()
    disconnect = c_mosquitto_disconnect mosq >> return ()

withConnack :: Mosq -> String -> Int -> Int -> Int -> IO a -> IO a
withConnack mosq hostname port keepAlive ackTimeout action = do
    ack <- newIORef False
    withConnectCallback mosq (connectCallback ack) $ do
                          withConnect mosq hostname port keepAlive (waitAck ack ackTimeout >> action)
  where
    connectCallback :: IORef Bool -> Mosq -> Int -> IO ()
    connectCallback ref _mosq result = do
      if result == 0
        then writeIORef ref True
        else return ()

    waitAck :: IORef Bool -> Int -> IO Bool
    waitAck ref timeout_msec = do
      if timeout_msec < 0
        then throwIO $ AssertionFailed "timeout: connection ack"
        else do
          _ <- c_mosquitto_loop mosq 10 1
          done <- readIORef ref
          if done
            then return True
            else threadDelay (10*1000) >> waitAck ref (timeout_msec - 10)

withConnectCallback :: Mosq -> ConnectCallback -> IO a -> IO a
withConnectCallback mosq callback action = bracket wrapCallback freeHaskellFunPtr (\_ -> action)
  where
    wrapCallback = do
      callbackC <- wrapOnConnectCallback callback'
      c_mosquitto_connect_callback_set mosq callbackC
      return callbackC
    callback' = (\m _userdata result -> callback m (fromIntegral result))

