{-# LANGUAGE ForeignFunctionInterface #-}
module Network.Mosquitto.C.Interface where

import Foreign.C.Types
import Foreign.C.String
import Foreign.Ptr(Ptr, FunPtr)
import Network.Mosquitto.C.Types

-- mosquitto - C functions

foreign import ccall "mosquitto.h mosquitto_lib_version"
  c_mosquitto_lib_version :: Ptr CInt -> Ptr CInt -> Ptr CInt -> IO CInt

foreign import ccall "mosquitto.h mosquitto_lib_init"
  c_mosquitto_lib_init :: IO CInt

foreign import ccall "mosquitto.h mosquitto_lib_cleanup"
  c_mosquitto_lib_cleanup :: IO CInt

foreign import ccall "mosquitto.h mosquitto_new"
  c_mosquitto_new :: CString -> CInt -> Ptr () -> IO Mosq

foreign import ccall "mosquitto.h mosquitto_destroy"
  c_mosquitto_destroy :: Mosq -> IO ()

foreign import ccall "mosquitto.h mosquitto_will_set"
  c_mosquitto_will_set :: Mosq -> CString -> CInt -> Ptr a -> CInt -> CInt -> IO CInt

foreign import ccall "mosquitto.h mosquitto_will_clear"
  c_mosquitto_will_clear :: Mosq -> IO CInt

foreign import ccall "mosquitto.h mosquitto_connect"
  c_mosquitto_connect :: Mosq -> CString -> CInt -> CInt -> IO CInt

foreign import ccall "mosquitto.h mosquitto_disconnect"
  c_mosquitto_disconnect :: Mosq -> IO CInt

foreign import ccall "mosquitto.h mosquitto_publish"
  c_mosquitto_publish :: Mosq -> Ptr CInt -> CString -> CInt-> Ptr a -> CInt -> CInt -> IO CInt

foreign import ccall "mosquitto.h mosquitto_subscribe"
  c_mosquitto_subscribe :: Mosq -> Ptr CInt -> CString -> CInt -> IO CInt

foreign import ccall "mosquitto.h mosquitto_loop"
  c_mosquitto_loop :: Mosq -> CInt -> CInt -> IO CInt

foreign import ccall "mosquitto.h mosquitto_loop_forever"
  c_mosquitto_loop_forever :: Mosq -> CInt -> CInt -> IO CInt

foreign import ccall "mosquitto.h mosquitto_connect_callback_set"
  c_mosquitto_connect_callback_set :: Mosq -> FunPtr (Mosq -> Ptr () -> CInt -> IO ()) -> IO ()

foreign import ccall "mosquitto.h mosquitto_disconnect_callback_set"
  c_mosquitto_disconnect_callback_set :: Mosq -> FunPtr (Mosq -> Ptr () -> CInt -> IO ()) -> IO ()

foreign import ccall "mosquitto.h mosquitto_publish_callback_set"
  c_mosquitto_publish_callback_set :: Mosq -> FunPtr (Mosq -> Ptr () -> CInt -> IO ()) -> IO ()

foreign import ccall "mosquitto.h mosquitto_message_callback_set"
  c_mosquitto_message_callback_set :: Mosq -> FunPtr (Mosq -> Ptr () -> Ptr MessageC -> IO ()) -> IO ()

foreign import ccall "mosquitto.h mosquitto_subscribe_callback_set"
  c_mosquitto_subscribe_callback_set :: Mosq -> FunPtr (Mosq -> Ptr () -> CInt -> CInt -> Ptr CInt -> IO ()) -> IO ()

foreign import ccall "mosquitto.h mosquitto_log_callback_set"
  c_mosquitto_log_callback_set :: Mosq -> FunPtr (Mosq -> Ptr () -> CInt -> CString -> IO ()) -> IO CInt

foreign import ccall "mosquitto.h mosquitto_strerror"
  c_mosquitto_strerror :: CInt -> IO CString


-- callback wrapper

foreign import ccall "wrapper"
  wrapOnConnectCallback :: (Mosq -> Ptr () -> CInt -> IO ()) -> IO (FunPtr (Mosq -> Ptr () -> CInt -> IO ()))

foreign import ccall "wrapper"
  wrapOnDisconnectCallback :: (Mosq -> Ptr () -> CInt -> IO ()) -> IO (FunPtr (Mosq -> Ptr () -> CInt -> IO ()))

foreign import ccall "wrapper"
  wrapOnPublishCallback :: (Mosq -> Ptr () -> CInt -> IO ()) -> IO (FunPtr (Mosq -> Ptr () -> CInt -> IO ()))

foreign import ccall "wrapper"
  wrapOnMessageCallback :: (Mosq -> Ptr () -> Ptr MessageC -> IO ()) -> IO (FunPtr (Mosq -> Ptr () -> Ptr MessageC -> IO ()))

foreign import ccall "wrapper"
  wrapOnSubscribeCallback :: (Mosq -> Ptr () -> CInt -> CInt -> Ptr CInt -> IO ()) -> IO (FunPtr (Mosq -> Ptr () -> CInt -> CInt -> Ptr CInt -> IO ()))

foreign import ccall "wrapper"
  wrapOnUnsubscribeCallback :: (Mosq -> Ptr () -> CInt -> CString -> IO ()) -> IO (FunPtr (Mosq -> Ptr () -> CInt -> CString -> IO ()))

