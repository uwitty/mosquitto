#include "mosquitto.h"
{-# LANGUAGE ForeignFunctionInterface #-}
module Network.Mosquitto.C.Types where

--import Foreign.Marshal.Alloc
import Foreign.Ptr
import Foreign.Storable

import Foreign.C.String
import Foreign.C.Types(CInt(..))
import Data.Word(Word8)

type Mosq = Ptr ()

#{enum CInt,
 , errConnPending  = MOSQ_ERR_CONN_PENDING
 , errSuccess      = MOSQ_ERR_SUCCESS
 , errNoMem        = MOSQ_ERR_NOMEM
 , errProtocol     = MOSQ_ERR_PROTOCOL
 , errInval        = MOSQ_ERR_INVAL
 , errNoConn       = MOSQ_ERR_NO_CONN
 , errConnRefused  = MOSQ_ERR_CONN_REFUSED
 , errNotFound     = MOSQ_ERR_NOT_FOUND
 , errConnLost     = MOSQ_ERR_CONN_LOST
 , errTLS          = MOSQ_ERR_TLS
 , errPayloadSize  = MOSQ_ERR_PAYLOAD_SIZE
 , errNotSupported = MOSQ_ERR_NOT_SUPPORTED
 , errAuth         = MOSQ_ERR_AUTH
 , errACLDenied    = MOSQ_ERR_ACL_DENIED
 , errUNknown      = MOSQ_ERR_UNKNOWN
 , errErrNo        = MOSQ_ERR_ERRNO
 , errEAI          = MOSQ_ERR_EAI
 }

data MessageC = MessageC { messageCID :: CInt
                         , messageCTopic :: CString
                         , messageCPayload :: Ptr Word8
                         , messageCPayloadLen :: CInt
                         , messageCQos :: CInt
                         , messageCRetain :: Bool
                         }

instance Storable MessageC where
    sizeOf = const #size struct mosquitto_message
    alignment = sizeOf
    poke message (MessageC mid topic payload payloadLen qos retain) = do
        (#poke struct mosquitto_message, mid)        message mid
        (#poke struct mosquitto_message, topic)      message topic
        (#poke struct mosquitto_message, payload)    message payload
        (#poke struct mosquitto_message, payloadlen) message payloadLen
        (#poke struct mosquitto_message, qos)        message qos
        (#poke struct mosquitto_message, retain)     message retain
    peek message = do
        mid        <- (#peek struct mosquitto_message, mid) message
        topic      <- (#peek struct mosquitto_message, topic) message
        payload    <- (#peek struct mosquitto_message, payload) message
        payloadLen <- (#peek struct mosquitto_message, payloadlen) message
        qos        <- (#peek struct mosquitto_message, qos) message
        retain     <- (#peek struct mosquitto_message, retain) message
        return $ MessageC mid topic payload payloadLen qos retain

