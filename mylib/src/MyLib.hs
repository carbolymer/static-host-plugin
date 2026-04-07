{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE ScopedTypeVariables #-}

module MyLib
  ( processMap
  , hs_process_map
  ) where

import Data.ProtoLens.Encoding (encodeMessage, decodeMessage)
import Data.ProtoLens.Message (Message (defMessage))
import Foreign.C.String (CString, newCString)
import Foreign.StablePtr (StablePtr, deRefStablePtr)
import Proto.Google.Protobuf.Wrappers (StringValue)
import Proto.Google.Protobuf.Wrappers_Fields (value)
import RIO
import qualified RIO.Map as Map

-- | Process a map: log each entry via RIO and return a summary.
-- Exercises proto-lens by round-tripping a StringValue through protobuf encoding.
processMap :: Map Text Text -> IO String
processMap m = do
  runSimpleApp $ do
    logInfo "MyLib.processMap called via dynamic loading"
    forM_ (Map.toList m) $ \(k, v) ->
      logInfo $ display k <> " -> " <> display v
    -- Exercise proto-lens: encode a StringValue and decode it back
    let wrapper :: StringValue
        wrapper = defMessage & value .~ "proto-lens works"
        encoded = encodeMessage wrapper
    case decodeMessage encoded of
      Right (decoded :: StringValue) ->
        logInfo $ "proto-lens round-trip: " <> display (decoded ^. value)
      Left err ->
        logError $ "proto-lens decode error: " <> displayShow err
  pure $ "Processed " ++ show (Map.size m) ++ " entries"

-- | C-callable wrapper. Takes a StablePtr to a Map, dereferences it, processes it.
hs_process_map :: StablePtr (Map Text Text) -> IO CString
hs_process_map sptr = do
  m <- deRefStablePtr sptr
  processMap m >>= newCString

foreign export ccall "hs_process_map" hs_process_map :: StablePtr (Map Text Text) -> IO CString
