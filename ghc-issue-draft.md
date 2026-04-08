# RTS linker `CHECK(lbl[0] == '_')` assertion in `lookupDependentSymbol` on darwin

## Summary

The RTS linker's public C API [`lookupSymbol`](https://gitlab.haskell.org/ghc/ghc/-/blob/master/rts/Linker.c#L976) crashes with `ASSERTION FAILED` on macOS (darwin) when the caller passes a symbol name without the Mach-O leading underscore prefix.

The Haskell wrapper `GHCi.ObjLink.lookupSymbol` correctly adds the prefix via `prefixUnderscore` before calling the C API, so GHCi/TH users are not affected.
However, direct C/FFI callers of the RTS `lookupSymbol` function have no way to know this requirement -- the API does not document it, and the Haskell-level prefix logic is not accessible from C.
When the lookup fails in `symhash` (because the name lacks `_`), the Mach-O fallback path hits [`CHECK(lbl[0] == '_')` at rts/Linker.c:872](https://gitlab.haskell.org/ghc/ghc/-/blob/master/rts/Linker.c#L872) and aborts the process.

This affects **all darwin platforms** (both x86_64-darwin and aarch64-darwin).

## Error output

GHC 9.6.7 on aarch64-darwin:

```
myexe: internal error: ASSERTION FAILED: file rts/Linker.c, line 952

    (GHC version 9.6.7 for aarch64_apple_darwin)
    Please report this as a GHC bug:  https://www.haskell.org/ghc/reportabug
```

GHC 9.12.2 on aarch64-darwin:

```
myexe: internal error: ASSERTION FAILED: file rts/Linker.c, line 866

    (GHC version 9.12.2 for aarch64_apple_darwin)
    Please report this as a GHC bug:  https://www.haskell.org/ghc/reportabug
```

Both correspond to `CHECK(lbl[0] == '_')` in [`lookupDependentSymbol`](https://gitlab.haskell.org/ghc/ghc/-/blob/master/rts/Linker.c#L805) (verified: [line 952 in 9.6.7](https://gitlab.haskell.org/ghc/ghc/-/blob/ghc-9.6.7-release/rts/Linker.c#L952), [line 866 in 9.12.2](https://gitlab.haskell.org/ghc/ghc/-/blob/ghc-9.12.2-release/rts/Linker.c#L866), [line 872 on master](https://gitlab.haskell.org/ghc/ghc/-/blob/master/rts/Linker.c#L872)).

## Steps to reproduce

### Repository

https://github.com/carbolymer/static-host-plugin/

### Quick reproduction (nix)

On an aarch64-darwin or x86_64-darwin machine:

```bash
nix build path:.#checks.aarch64-darwin.dynamic-load   # on Apple Silicon
nix build path:.#checks.x86_64-darwin.dynamic-load     # on Intel Mac
```

### What the reproduction does

Two cabal packages: `myexe` (executable) and `mylib` (library with `foreign export ccall`).
`myexe` uses the RTS linker C API directly via FFI:

```haskell
-- Runtime/Linker.hs -- direct FFI bindings to RTS C API
foreign import ccall "initLinker_" rts_initLinker :: IO ()
foreign import ccall "loadArchive" rts_loadArchive :: CString -> IO Int
foreign import ccall "resolveObjs" rts_resolveObjs :: IO Int
foreign import ccall "lookupSymbol" rts_lookupSymbol :: CString -> IO (Ptr ())
```

```haskell
-- Main.hs
main = do
  initLinker
  mapM_ loadArchive archives     -- ~60 Haskell .a archives (boot libs + deps)
  resolveObjs                    -- succeeds (archive members are OBJECT_LOADED, not OBJECT_NEEDED)
  lookupSymbol "hs_process_map"  -- CRASH: name lacks leading underscore on darwin
```

```haskell
-- MyLib.hs -- the dynamically loaded library
foreign export ccall "hs_process_map"
  hs_process_map :: StablePtr (Map Text Text) -> IO CString
```

The same code works on x86_64-linux and aarch64-linux (ELF has no underscore prefix convention).

## Root cause analysis

### How symbol names work on Mach-O

On darwin (Mach-O), all external C symbols have a leading underscore in the object file.
`foreign export ccall "hs_process_map"` generates a C symbol which Mach-O stores as `_hs_process_map` in the nlist table.

When [`ocGetNames_MachO`](https://gitlab.haskell.org/ghc/ghc/-/blob/master/rts/linker/MachO.c) loads an archive member, it inserts the nlist name (with underscore) into `symhash`.
So `symhash` contains `_hs_process_map`, not `hs_process_map`.

### The crash path

1. User calls [`lookupSymbol("hs_process_map")`](https://gitlab.haskell.org/ghc/ghc/-/blob/master/rts/Linker.c#L976) via FFI (no underscore).
2. [`lookupDependentSymbol`](https://gitlab.haskell.org/ghc/ghc/-/blob/master/rts/Linker.c#L805) checks [`symhash`](https://gitlab.haskell.org/ghc/ghc/-/blob/master/rts/Linker.c#L837) for `"hs_process_map"` -- **not found** (stored as `"_hs_process_map"`).
3. Falls through to the [`OBJFORMAT_MACHO` dlsym fallback](https://gitlab.haskell.org/ghc/ghc/-/blob/master/rts/Linker.c#L862):
   ```c
   /* HACK: On OS X, all symbols are prefixed with an underscore.
            However, dlsym wants us to omit the leading underscore from the
            symbol name -- the dlsym routine puts it back on before
            searching for the symbol. For now, we simply strip it off here
            (and ONLY here).
   */
   CHECK(lbl[0] == '_');           // line 872 -- 'h' != '_', CRASH
   return internal_dlsym(lbl + 1); // line 878 -- never reached
   ```
4. `CHECK('h' == '_')` fails, process aborts via `barf()`.

### Why it works on Linux

On ELF (Linux, including musl), there is no leading underscore convention.
`symhash` stores `hs_process_map` directly, and `lookupSymbol("hs_process_map")` finds it immediately.
The `OBJFORMAT_ELF` fallback path ([line 841](https://gitlab.haskell.org/ghc/ghc/-/blob/master/rts/Linker.c#L841)) calls `internal_dlsym(lbl)` without any underscore assertion, so even cache misses are safe.

### Why resolveObjs is not involved

[`loadArchive`](https://gitlab.haskell.org/ghc/ghc/-/blob/master/rts/Linker.c) loads object files as `OBJECT_LOADED` and registers their symbols in `symhash`.
[`resolveObjs`](https://gitlab.haskell.org/ghc/ghc/-/blob/master/rts/Linker.c#L1724) iterates objects and calls [`ocTryLoad`](https://gitlab.haskell.org/ghc/ghc/-/blob/master/rts/Linker.c#L1606), which [immediately returns 1 when `status != OBJECT_NEEDED`](https://gitlab.haskell.org/ghc/ghc/-/blob/master/rts/Linker.c#L1609).
Since archive members are `OBJECT_LOADED` (not `OBJECT_NEEDED`), `resolveObjs` is effectively a no-op -- no relocations are processed, no symbols are looked up.
The crash occurs later, at the explicit `lookupSymbol` call.

### The Haskell wrapper handles this correctly

`GHCi.ObjLink.lookupSymbol` uses `prefixUnderscore` (which checks `cLeadingUnderscore` from the GHC settings) to prepend `_` before calling the C API.
Direct C/FFI callers have no access to this logic and no documentation telling them to add the prefix.

## Platform

- **OS**: macOS (darwin) -- both x86_64 and aarch64
- **GHC versions tested**: 9.6.7, 9.12.2 (the CHECK exists on master too)
- **Not affected**: Linux (x86_64-linux, aarch64-linux, musl64) -- ELF has no underscore convention

## Expected behaviour

The public C API `lookupSymbol` should handle the platform's symbol prefix convention transparently, matching the behaviour of the Haskell wrapper.
Alternatively, the `CHECK` should be replaced with a graceful error (return NULL) instead of aborting the process.

## Suggested fixes

### Option A: Add prefix in the `lookupSymbol` C API

Make [`lookupSymbol`](https://gitlab.haskell.org/ghc/ghc/-/blob/master/rts/Linker.c#L976) add the platform prefix before calling `lookupDependentSymbol`, matching the Haskell wrapper:

```c
SymbolAddr* lookupSymbol( SymbolName* lbl )
{
    ACQUIRE_LOCK(&linker_mutex);
#if defined(LEADING_UNDERSCORE)
    size_t len = strlen(lbl);
    char *prefixed = stgMallocBytes(len + 2, "lookupSymbol");
    prefixed[0] = '_';
    memcpy(prefixed + 1, lbl, len + 1);
    SymbolAddr* r = lookupDependentSymbol(prefixed, NULL, NULL);
    stgFree(prefixed);
#else
    SymbolAddr* r = lookupDependentSymbol(lbl, NULL, NULL);
#endif
    // ... rest unchanged
```

### Option B: Harden the dlsym fallback

Replace the unconditional [`CHECK` at line 872](https://gitlab.haskell.org/ghc/ghc/-/blob/master/rts/Linker.c#L872) with a graceful fallback:

```c
#elif defined(OBJFORMAT_MACHO)
    if (lbl[0] != '_') {
        IF_DEBUG(linker, debugBelch("lookupDependentSymbol: "
            "symbol '%s' lacks leading underscore on Mach-O\n", lbl));
        return NULL;
    }
    return internal_dlsym(lbl + 1);
```

Option A is preferred because it makes the C API consistent with the Haskell wrapper, rather than silently returning NULL for valid symbol names.
