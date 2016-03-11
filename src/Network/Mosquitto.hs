module Network.Mosquitto (
    -- * Data structure
      Mosquitto
    , Event(..)
    -- * Mosquitto
    , initializeMosquittoLib
    , cleanupMosquittoLib
    , newMosquitto
    , destroyMosquitto
    , setWill
    , clearWill
    , connect
    , disconnect
    , getNextEvents
    , subscribe
    , publish
    -- * Helper
    , withInit
    , withMosquitto
    , withConnect
    -- * Utility
    , strerror
    ) where

import Network.Mosquitto.C.Interface
import Network.Mosquitto.C.Types

import Control.Monad
import Control.Monad.IO.Class
import Data.IORef
import qualified Data.ByteString as BS
import Data.ByteString.Internal(toForeignPtr)
import Control.Exception(bracket, bracket_, throwIO, AssertionFailed(..))
import Foreign.Ptr(Ptr, FunPtr, nullPtr, plusPtr, castFunPtr, freeHaskellFunPtr)
import Foreign.ForeignPtr(withForeignPtr)
import Foreign.Storable(peek)
import Foreign.C.String(withCString, peekCString)
import Foreign.C.Types(CInt(..))
import Foreign.Marshal.Array(peekArray)
import Foreign.Marshal.Utils(fromBool)
import Foreign.Marshal.Alloc(malloc, free)

data Mosquitto = Mosquitto
                     { mosquittoObject    :: !Mosq
                     , mosquittoEvents    :: IORef [Event]
                     , mosquittoCallbacks :: ![FunPtr ()]
                     }

data Event = Message
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
           | Published { messageID :: !Int }
  deriving Show

initializeMosquittoLib :: IO ()
initializeMosquittoLib = do
    result <- c_mosquitto_lib_init
    when (result /= 0) $ do
        msg <- strerror $ fromIntegral result
        throwIO $ AssertionFailed $ "initializeMosquitto: " ++ msg

cleanupMosquittoLib :: IO ()
cleanupMosquittoLib = do
    result <- c_mosquitto_lib_cleanup
    when (result /= 0) $ do
        msg <- strerror $ fromIntegral result
        throwIO $ AssertionFailed $ "cleanupMosquittoLib: " ++ msg

newMosquitto :: Maybe String -> IO Mosquitto
newMosquitto Nothing  = c_mosquitto_new nullPtr 1 nullPtr >>= newMosquitto'
newMosquitto (Just s) = (withCString s $ \sC ->
                           c_mosquitto_new sC 1 nullPtr) >>= newMosquitto'

newMosquitto' :: Mosq -> IO Mosquitto
newMosquitto' mosq = if mosq == nullPtr
    then throwIO $ AssertionFailed "invalid mosq object"
    else do
        events <- newIORef ([] :: [Event])
        connectCallbackC <- wrapOnConnectCallback (connectCallback events)
        c_mosquitto_connect_callback_set mosq connectCallbackC
        messageCallbackC <- wrapOnMessageCallback (messageCallback events)
        c_mosquitto_message_callback_set mosq messageCallbackC
        disconnectCallbackC <- wrapOnDisconnectCallback (disconnectCallback events)
        c_mosquitto_disconnect_callback_set mosq disconnectCallbackC
        publishCallbackC <- wrapOnPublishCallback (publishCallback events)
        c_mosquitto_publish_callback_set mosq publishCallbackC
        return Mosquitto { mosquittoObject    = mosq
                         , mosquittoEvents    = events
                         , mosquittoCallbacks = [ castFunPtr connectCallbackC
                                                , castFunPtr messageCallbackC
                                                , castFunPtr disconnectCallbackC
                                                , castFunPtr publishCallbackC
                                                ]
                         }
  where
    connectCallback :: IORef [Event] -> Mosq -> Ptr () -> CInt -> IO ()
    connectCallback events _mosq _ result = do
        let code = fromIntegral result
        str <- strerror code
        pushEvent events $ ConnectResult code str
    messageCallback :: IORef [Event] -> Mosq -> Ptr () -> Ptr MessageC -> IO ()
    messageCallback events _mosq _ messageC = do
        msg   <- peek messageC
        topic <- peekCString (messageCTopic msg)
        payload <- peekArray (fromIntegral $ messageCPayloadLen msg) (messageCPayload msg)
        pushEvent events $ Message (fromIntegral $ messageCID msg)
                                   topic
                                   (BS.pack payload)
                                   (fromIntegral $ messageCQos msg)
                                   (messageCRetain msg)
    disconnectCallback :: IORef [Event] -> Mosq -> Ptr () -> CInt -> IO ()
    disconnectCallback events _mosq _ result = do
        let code = fromIntegral result
        str <- strerror code
        pushEvent events $ DisconnectResult code str
    publishCallback :: IORef [Event] -> Mosq -> Ptr () -> CInt -> IO ()
    publishCallback events _mosq _ mid = do
        pushEvent events $ Published (fromIntegral mid)
    pushEvent :: IORef [Event] -> Event -> IO ()
    pushEvent ref e = do
        es <- readIORef ref
        writeIORef ref (e:es)

destroyMosquitto :: Mosquitto -> IO ()
destroyMosquitto mosquitto = do
    mapM_ freeHaskellFunPtr (mosquittoCallbacks mosquitto)
    writeIORef (mosquittoEvents mosquitto) []
    c_mosquitto_destroy (mosquittoObject mosquitto)

setWill :: Mosquitto -> String -> BS.ByteString -> Int -> Bool -> IO Int
setWill mosquitto topicName payload qos retain = do
    let (payloadFP, off, _len) = toForeignPtr payload
    fmap fromIntegral $ withCString topicName $ \topicNameC ->
                        withForeignPtr payloadFP $ \payloadP -> do
                          c_mosquitto_will_set (mosquittoObject mosquitto)
                                               topicNameC
                                               (fromIntegral (BS.length payload))
                                               (payloadP `plusPtr` off)
                                               (fromIntegral qos)
                                               (fromBool retain)

clearWill :: Mosquitto -> IO Int
clearWill mosquitto = c_mosquitto_will_clear (mosquittoObject mosquitto) >>= return . fromIntegral

connect :: Mosquitto -> String -> Int -> Int -> IO Int
connect mosquitto hostname port keepAlive =
    fmap fromIntegral . withCString hostname $ \hostnameC ->
        c_mosquitto_connect (mosquittoObject mosquitto) hostnameC (fromIntegral port) (fromIntegral keepAlive)

disconnect :: Mosquitto -> IO Int
disconnect mosquitto =
    fmap fromIntegral . c_mosquitto_disconnect $ mosquittoObject mosquitto

getNextEvents :: Mosquitto -> Int -> IO (Int, [Event])
getNextEvents mosquitto timeout = do
    result <- fmap fromIntegral . liftIO $ c_mosquitto_loop (mosquittoObject mosquitto) (fromIntegral timeout) 1
    if result == 0
        then do events <- liftIO . fmap reverse $ readIORef (mosquittoEvents mosquitto)
                writeIORef (mosquittoEvents mosquitto) []
                return (result, events)
        else return (result, [])

subscribe :: Mosquitto -> String -> Int -> IO Int
subscribe mosquitto topicName qos = do
    fmap fromIntegral . withCString topicName $ \topicNameC ->
      c_mosquitto_subscribe (mosquittoObject mosquitto) nullPtr topicNameC (fromIntegral qos)

publish :: Mosquitto -> String -> BS.ByteString -> Int -> Bool -> IO (Int, Int)
publish mosquitto topicName payload qos retain = do
    midC <- (malloc :: IO (Ptr CInt))
    let (payloadFP, off, _len) = toForeignPtr payload
    res <- fmap fromIntegral $ withCString topicName $ \topicNameC ->
                               withForeignPtr payloadFP $ \payloadP ->
                                 c_mosquitto_publish (mosquittoObject mosquitto)
                                                     midC
                                                     topicNameC
                                                     (fromIntegral (BS.length payload))
                                                     (payloadP `plusPtr` off)
                                                     (fromIntegral qos)
                                                     (fromBool retain)
    mid <- fromIntegral <$> peek midC
    free midC
    return (res, mid)

-- Utility

strerror :: Int -> IO String
strerror err = c_mosquitto_strerror (fromIntegral err) >>= peekCString

-- Helper

withInit :: IO a -> IO a
withInit = bracket_ initializeMosquittoLib cleanupMosquittoLib

withMosquitto :: Maybe String -> (Mosquitto -> IO a) -> IO a
withMosquitto clientId = bracket (newMosquitto clientId) destroyMosquitto

withConnect :: Mosquitto -> String -> Int -> Int -> IO a -> IO a
withConnect mosquitto hostname port keepAlive = bracket_ connectI (disconnect mosquitto)
  where
    connectI :: IO ()
    connectI = do
      result <- connect mosquitto hostname (fromIntegral port) (fromIntegral keepAlive)
      when (result /= 0) $ do
          err <- strerror result
          throwIO $ AssertionFailed $ "withConnect:" ++ (show result) ++ ": " ++ err

