{-# LANGUAGE ForeignFunctionInterface #-}

module MyLib
  ( processMap
  , hs_process_map
  ) where

import Foreign.C.String (CString, newCString)
import Foreign.StablePtr (StablePtr, deRefStablePtr)
import RIO
import qualified RIO.Map as Map

-- | Process a map: log each entry via RIO and return a summary.
processMap :: Map Text Text -> IO String
processMap m = do
  runSimpleApp $ do
    logInfo "MyLib.processMap called via dynamic loading"
    forM_ (Map.toList m) $ \(k, v) ->
      logInfo $ display k <> " -> " <> display v
  pure $ "Processed " ++ show (Map.size m) ++ " entries"

-- | C-callable wrapper. Takes a StablePtr to a Map, dereferences it, processes it.
hs_process_map :: StablePtr (Map Text Text) -> IO CString
hs_process_map sptr = do
  m <- deRefStablePtr sptr
  processMap m >>= newCString

foreign export ccall "hs_process_map" hs_process_map :: StablePtr (Map Text Text) -> IO CString
