{-# LANGUAGE ForeignFunctionInterface #-}

module Runtime.Linker
  ( initLinker
  , loadObj
  , loadArchive
  , resolveObjs
  , lookupSymbol
  , unloadObj
  ) where

import Foreign.C.String (CString, withCString)
import Foreign.Ptr (Ptr)

-- RTS linker API -- these symbols are in libHSrts
foreign import ccall "initLinker_" rts_initLinker :: IO ()
foreign import ccall "loadObj" rts_loadObj :: CString -> IO Int
foreign import ccall "loadArchive" rts_loadArchive :: CString -> IO Int
foreign import ccall "resolveObjs" rts_resolveObjs :: IO Int
foreign import ccall "lookupSymbol" rts_lookupSymbol :: CString -> IO (Ptr ())
foreign import ccall "unloadObj" rts_unloadObj :: CString -> IO Int

initLinker :: IO ()
initLinker = rts_initLinker

loadObj :: FilePath -> IO Bool
loadObj path = withCString path $ \cpath -> do
  r <- rts_loadObj cpath
  pure (r == 1)

loadArchive :: FilePath -> IO Bool
loadArchive path = withCString path $ \cpath -> do
  r <- rts_loadArchive cpath
  pure (r == 1)

resolveObjs :: IO Bool
resolveObjs = do
  r <- rts_resolveObjs
  pure (r == 1)

lookupSymbol :: String -> IO (Ptr ())
lookupSymbol sym = withCString sym $ \csym ->
  rts_lookupSymbol csym

unloadObj :: FilePath -> IO Bool
unloadObj path = withCString path $ \cpath -> do
  r <- rts_unloadObj cpath
  pure (r == 1)
