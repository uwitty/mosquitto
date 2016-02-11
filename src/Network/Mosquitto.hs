module Network.Mosquitto (
    -- * Data structure
      MosqContext
    , MosqEvent(..)
    -- * Mosquitto
    , setWill
    , clearWill
    , connect
    , disconnect
    , getNextEvents
    , subscribe
    , publish
    -- * Helper
    , withInit
    , withMosqContext
    , withConnect
    -- * Utility
    , strerror
    ) where

import Network.Mosquitto.C.Interface
import Network.Mosquitto.C.Types

import Control.Monad.IO.Class
import Data.IORef
import Data.Maybe(isJust, fromJust)
import qualified Data.ByteString as BS
import Data.ByteString.Internal(toForeignPtr)
import Control.Exception(bracket, bracket_, throwIO, AssertionFailed(..))
import Foreign.Ptr(Ptr, FunPtr, nullPtr, plusPtr, castFunPtr, freeHaskellFunPtr)
import Foreign.ForeignPtr(withForeignPtr)
import Foreign.Storable(peek)
import Foreign.C.String(withCStringLen, peekCString)
import Foreign.C.Types(CInt(..))
import Foreign.Marshal.Array(peekArray)

data MosqContext = MosqContext
                       { contextMosq      :: !Mosq
                       , contextEvents    :: IORef [MosqEvent]
                       , contextCallbacks :: ![FunPtr ()]
                       }

data MosqEvent = Message 
                     { messageID      :: !Int
                     , messageTopic   :: !String
                     , messagePayload :: !BS.ByteString
                     , messageQos     :: !Int
                     , messageRetain  :: !Bool
                     }
               | ConnectResult
                     { connectResultCode   :: !Int
                     , connectResultString :: !String
                     }
               | DisconnectResult
                     { disconnectResultCode   :: !Int
                     , disconnectResultString :: !String
                     }
  deriving Show

newMosqContext :: Mosq -> IO MosqContext
newMosqContext mosq = if mosq == nullPtr
    then throwIO $ AssertionFailed "invalid mosq object"
    else do
        events <- newIORef ([] :: [MosqEvent])
        connectCallbackC <- wrapOnConnectCallback (connectCallback events)
        c_mosquitto_connect_callback_set mosq connectCallbackC
        messageCallbackC <- wrapOnMessageCallback (messageCallback events)
        c_mosquitto_message_callback_set mosq messageCallbackC
        disconnectCallbackC <- wrapOnDisconnectCallback (disconnectCallback events)
        c_mosquitto_disconnect_callback_set mosq disconnectCallbackC
        return MosqContext { contextMosq = mosq
                           , contextEvents = events
                           , contextCallbacks = [ castFunPtr connectCallbackC
                                                , castFunPtr messageCallbackC
                                                , castFunPtr disconnectCallbackC
                                                ]
                           }
  where
    connectCallback :: IORef [MosqEvent] -> Mosq -> Ptr () -> CInt -> IO ()
    connectCallback events _mosq _ result = do
        let code = fromIntegral result
        str <- strerror code
        pushEvent events $ ConnectResult code str
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
    disconnectCallback :: IORef [MosqEvent] -> Mosq -> Ptr () -> CInt -> IO ()
    disconnectCallback events _mosq _ result = do
        let code = fromIntegral result
        str <- strerror code
        pushEvent events $ DisconnectResult code str

freeMosqContext :: MosqContext -> IO ()
freeMosqContext context = mapM_ freeHaskellFunPtr (contextCallbacks context)

pushEvent :: IORef [MosqEvent] -> MosqEvent -> IO ()
pushEvent ref e = do
    es <- readIORef ref
    writeIORef ref (e:es)

setWill :: MosqContext -> String -> BS.ByteString -> Int -> Bool -> IO Int
setWill context topicName payload qos retain = do
    let (payloadFP, off, _len) = toForeignPtr payload
    fmap fromIntegral $ withCStringLen topicName $ \(topicNameC, _) ->
                        withForeignPtr payloadFP $ \payloadP -> do
                          c_mosquitto_will_set (contextMosq context)
                                               topicNameC
                                               (fromIntegral (BS.length payload))
                                               (payloadP `plusPtr` off)
                                               (fromIntegral qos)
                                               (if retain then 1 else 0)

clearWill :: MosqContext -> IO Int
clearWill context = c_mosquitto_will_clear (contextMosq context) >>= return . fromIntegral

connect :: MosqContext -> String -> Int -> Int -> IO Int
connect context hostname port keepAlive =
    fmap fromIntegral . withCStringLen hostname $ \(hostnameC, _len) ->
        c_mosquitto_connect (contextMosq context) hostnameC (fromIntegral port) (fromIntegral keepAlive)

disconnect :: MosqContext -> IO Int
disconnect context =
    fmap fromIntegral . c_mosquitto_disconnect $ contextMosq context

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
    let (payloadFP, off, _len) = toForeignPtr payload
    fmap fromIntegral $ withCStringLen topicName $ \(topicNameC, _) ->
                        withForeignPtr payloadFP $ \payloadP ->
                          c_mosquitto_publish (contextMosq context)
                                              nullPtr
                                              topicNameC
                                              (fromIntegral (BS.length payload))
                                              (payloadP `plusPtr` off)
                                              (fromIntegral qos)
                                              (if retain then 1 else 0)

-- Utility

strerror :: Int -> IO String
strerror err = c_mosquitto_strerror (fromIntegral err) >>= peekCString

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

withConnect :: MosqContext -> String -> Int -> Int -> IO a -> IO a
withConnect context hostname port keepAlive = bracket_ connectI (disconnect context)
  where
    connectI :: IO ()
    connectI = do
      result <- connect context hostname (fromIntegral port) (fromIntegral keepAlive)
      if result == 0
        then return ()
        else throwIO $ AssertionFailed $ "failed to connect: " ++ (show result)

