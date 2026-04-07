{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}

module GitRev
  ( gitRev
  ) where

import Data.Text (Text)
import qualified Data.Text as Text
import Foreign.C.String (CString)
import GHC.Foreign (peekCStringLen)
import System.IO (utf8)
import System.IO.Unsafe (unsafeDupablePerformIO)

foreign import ccall "&_cardano_git_rev" c_gitrev :: CString

-- | Git revision embedded after compilation using set-git-rev.
-- If nothing has been injected, this will be filled with 0 characters.
gitRev :: Text
gitRev =
  let raw = Text.pack $ drop 28 $ unsafeDupablePerformIO $ peekCStringLen utf8 (c_gitrev, 68)
  in if raw == zeroRev then "UNKNOWN" else raw

zeroRev :: Text
zeroRev = "0000000000000000000000000000000000000000"
