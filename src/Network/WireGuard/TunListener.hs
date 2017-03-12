{-# LANGUAGE CPP             #-}
{-# LANGUAGE RecordWildCards #-}

module Network.WireGuard.TunListener
  ( runTunListener
  ) where

import           Control.Concurrent.Async               (wait, withAsync)
import           Control.Monad                          (forever, void)
import           Control.Monad.STM                      (atomically)
import qualified Data.ByteArray                         as BA
import           Data.Word                              (Word8)
import           Foreign.Marshal.Alloc                  (allocaBytes)
import           Foreign.Ptr                            (Ptr)
import           System.Posix.Types                     (Fd)

import           Network.WireGuard.Foreign.Tun          (fdReadBuf, fdWriteBuf)

import           Network.WireGuard.Internal.Constant
import           Network.WireGuard.Internal.PacketQueue
import           Network.WireGuard.Internal.Types
import           Network.WireGuard.Internal.Util

#ifdef OS_LINUX
import           Control.Concurrent                     (threadWaitRead,
                                                         threadWaitWrite)
#endif

runTunListener :: [Fd] -> PacketQueue TunPacket -> PacketQueue TunPacket -> IO ()
runTunListener fds readTunChan writeTunChan = loop fds []
  where
    loop [] asyncs = mapM_ wait asyncs
    loop (fd:rest) asyncs =
        withAsync (retryWithBackoff $ handleRead readTunChan fd) $ \rt ->
        withAsync (retryWithBackoff $ handleWrite writeTunChan fd) $ \wt ->
            loop rest (rt:wt:asyncs)

handleRead :: PacketQueue TunPacket -> Fd -> IO ()
handleRead readTunChan fd = allocaBytes tunReadBufferLength $ \buf ->
    forever (readFd buf fd >>= atomically . pushPacketQueue readTunChan)

handleWrite :: PacketQueue TunPacket -> Fd -> IO ()
handleWrite writeTunChan fd =
    forever (atomically (popPacketQueue writeTunChan) >>= writeFd fd)

readFd :: BA.ByteArray ba => Ptr Word8 -> Fd -> IO ba
readFd buf fd = do
#ifdef OS_LINUX
    threadWaitRead fd
#endif
    nbytes <- fdReadBuf fd buf (fromIntegral tunReadBufferLength)
    snd <$> BA.allocRet (fromIntegral nbytes)
        (\ptr -> copyMemory ptr buf nbytes >> zeroMemory buf nbytes)

writeFd :: BA.ByteArrayAccess ba => Fd -> ba -> IO ()
writeFd fd ba = BA.withByteArray ba $ \ptr -> do
#ifdef OS_LINUX
    threadWaitWrite fd
#endif
    void $ fdWriteBuf fd ptr (fromIntegral (BA.length ba))