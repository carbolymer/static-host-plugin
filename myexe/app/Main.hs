{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Foreign.C.String (CString, peekCString)
import Foreign.Ptr (FunPtr, castPtrToFunPtr, nullPtr)
import Foreign.StablePtr (StablePtr, freeStablePtr, newStablePtr)
import Runtime.Linker (initLinker, loadArchive, loadObj, lookupSymbol, resolveObjs)
import System.Environment (getArgs)
import System.Exit (exitFailure)

foreign import ccall "dynamic"
  mkProcessMap :: FunPtr (StablePtr (Map Text Text) -> IO CString) -> StablePtr (Map Text Text) -> IO CString

main :: IO ()
main = do
  args <- getArgs
  case args of
    [] -> do
      putStrLn "Usage: myexe [dep1.a dep2.a ...] MyLib.o"
      exitFailure
    _ -> pure ()

  let archives = filter isArchive args
      objects = filter isObject args

  initLinker

  mapM_ (\a -> putStrLn ("Loading archive: " ++ a) >> loadArchive a >>= checkLoad a) archives
  mapM_ (\o -> putStrLn ("Loading object: " ++ o) >> loadObj o >>= checkLoad o) objects

  resolved <- resolveObjs
  if resolved
    then putStrLn "All symbols resolved successfully."
    else do
      putStrLn "ERROR: Failed to resolve symbols."
      exitFailure

  ptr <- lookupSymbol "hs_process_map"
  if ptr == nullPtr
    then do
      putStrLn "ERROR: Symbol 'hs_process_map' not found."
      exitFailure
    else do
      let processMapFn = mkProcessMap $ castPtrToFunPtr ptr

      let theMap :: Map Text Text
          theMap = Map.fromList
            [ ("name", "static-dylib")
            , ("version", "0.1.0.0")
            , ("status", "dynamically loaded")
            ]

      sptr <- newStablePtr theMap
      cstr <- processMapFn sptr
      result <- peekCString cstr
      putStrLn result
      freeStablePtr sptr

checkLoad :: String -> Bool -> IO ()
checkLoad path False = do
  putStrLn $ "ERROR: Failed to load " ++ path
  exitFailure
checkLoad _ True = pure ()

isArchive :: String -> Bool
isArchive = hasSuffix ".a"

isObject :: String -> Bool
isObject = hasSuffix ".o"

hasSuffix :: String -> String -> Bool
hasSuffix suffix str = drop (length str - length suffix) str == suffix
