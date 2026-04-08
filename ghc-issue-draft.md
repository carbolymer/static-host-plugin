# RTS linker `CHECK(lbl[0] == '_')` assertion in `lookupDependentSymbol` on aarch64-darwin

## Summary

The RTS linker crashes with `ASSERTION FAILED` in [`lookupDependentSymbol`](https://gitlab.haskell.org/ghc/ghc/-/blob/master/rts/Linker.c#L805) (`rts/Linker.c`) on aarch64-darwin when loading `.a` archives via the C API (`loadArchive`/`resolveObjs`/`lookupSymbol`).
Reproducible on GHC 9.6.7 and 9.12.2.
The same code works on x86_64-linux, aarch64-linux, and x86_64-darwin.

## Error output

GHC 9.6.7:

```
myexe: internal error: ASSERTION FAILED: file rts/Linker.c, line 952

    (GHC version 9.6.7 for aarch64_apple_darwin)
    Please report this as a GHC bug:  https://www.haskell.org/ghc/reportabug
```

GHC 9.12.2:

```
myexe: internal error: ASSERTION FAILED: file rts/Linker.c, line 866

    (GHC version 9.12.2 for aarch64_apple_darwin)
    Please report this as a GHC bug:  https://www.haskell.org/ghc/reportabug
```

## Steps to reproduce

### Repository

https://github.com/carbolymer/static-host-plugin/

### Quick reproduction (nix)

On an aarch64-darwin machine:

```bash
nix build path:.#checks.aarch64-darwin.dynamic-load
```

### What the reproduction does

Two cabal packages: `myexe` (executable) and `mylib` (library with `foreign export ccall`).
`myexe` uses the RTS linker C API directly via FFI to load `mylib`'s `.a` archives at runtime:

```haskell
-- Runtime/Linker.hs -- direct FFI to RTS C API
foreign import ccall "initLinker_" rts_initLinker :: IO ()
foreign import ccall "loadArchive" rts_loadArchive :: CString -> IO Int
foreign import ccall "resolveObjs" rts_resolveObjs :: IO Int
foreign import ccall "lookupSymbol" rts_lookupSymbol :: CString -> IO (Ptr ())
```

```haskell
-- Main.hs -- loads ~60 archives then looks up a symbol
main = do
  initLinker
  mapM_ loadArchive archives   -- base, ghc-internal, text, containers, rio, mylib, ...
  resolveObjs                  -- crash may occur here (cascading resolution)
  lookupSymbol "hs_process_map"  -- or here
```

```haskell
-- MyLib.hs -- the dynamically loaded function
foreign export ccall "hs_process_map"
  hs_process_map :: StablePtr (Map Text Text) -> IO CString
```

## Root cause analysis

The assertion is in [`lookupDependentSymbol` at rts/Linker.c:872](https://gitlab.haskell.org/ghc/ghc/-/blob/master/rts/Linker.c#L872) (GHC master):

```c
#elif defined(OBJFORMAT_MACHO)
    /* HACK: On OS X, all symbols are prefixed with an underscore.
             However, dlsym wants us to omit the leading underscore from the
             symbol name -- the dlsym routine puts it back on before
             searching for the symbol. For now, we simply strip it off here
             (and ONLY here).
    */
    CHECK(lbl[0] == '_');           // line 872
    return internal_dlsym(lbl + 1); // line 878
```

When a symbol is not found in `symhash`, the Mach-O fallback path assumes the label starts with `_` and strips it before calling `dlsym`.
`CHECK` fires in all builds (not just debug), so this is a hard crash with no workaround.

There are two code paths that can reach this `CHECK` with a non-underscore label:

### Path 1: Missing `r_extern` check in aarch64 Mach-O relocation handling

This is the likely trigger when loading many archives (crash during cascading `resolveObjs`).

In `rts/linker/MachO.c`, the x86_64 relocation handler [`relocateSection`](https://gitlab.haskell.org/ghc/ghc/-/blob/master/rts/linker/MachO.c#L737) has a clean three-way dispatch on `r_extern`:

```c
// x86_64 path -- three-way dispatch in relocateSection (rts/linker/MachO.c)

// 1. GOT relocations (line 835)
if (type == X86_64_RELOC_GOT        // https://gitlab.haskell.org/ghc/ghc/-/blob/master/rts/linker/MachO.c#L835
 || type == X86_64_RELOC_GOT_LOAD)
{
    if (reloc->r_extern == 0) {      // https://gitlab.haskell.org/ghc/ghc/-/blob/master/rts/linker/MachO.c#L845
        errorBelch("...");           // explicit r_extern == 0 check
    }
    // ...
}
// 2. External relocations (line 900)
else if (reloc->r_extern) {         // https://gitlab.haskell.org/ghc/ghc/-/blob/master/rts/linker/MachO.c#L900
    MachOSymbol *symbol = &symbols[reloc->r_symbolnum];  // symbol index -- correct
    // ...
}
// 3. Internal relocations (line 934)
else {                               // https://gitlab.haskell.org/ghc/ghc/-/blob/master/rts/linker/MachO.c#L934
    // r_extern == 0: r_symbolnum is a 1-based SECTION ORDINAL
    int targetSecNum = reloc->r_symbolnum - 1;  // line 951
    Section *targetSec = &oc->sections[targetSecNum];
    // computes relocated address from section base, no symbol lookup
}
```

The aarch64 relocation handler [`relocateSectionAarch64`](https://gitlab.haskell.org/ghc/ghc/-/blob/master/rts/linker/MachO.c#L584) (lines 584-732) **never checks `ri->r_extern`** for any relocation type.
Every handler blindly uses `ri->r_symbolnum` as a symbol array index:

```c
// aarch64 path (buggy) -- no r_extern check anywhere

case ARM64_RELOC_UNSIGNED: {        // https://gitlab.haskell.org/ghc/ghc/-/blob/master/rts/linker/MachO.c#L607
    MachOSymbol* symbol = &oc->info->macho_symbols[ri->r_symbolnum];  // line 608
    uint64_t value = symbol_value(oc, symbol);  // calls lookupDependentSymbol if N_EXT
    // ...
}
case ARM64_RELOC_SUBTRACTOR:        // https://gitlab.haskell.org/ghc/ghc/-/blob/master/rts/linker/MachO.c#L614
{
    MachOSymbol* symbol1 = &oc->info->macho_symbols[ri->r_symbolnum];  // line 635
    // ...
    MachOSymbol* symbol2 = &oc->info->macho_symbols[ri2->r_symbolnum]; // line 640
    // ...
}
case ARM64_RELOC_BRANCH26: {        // https://gitlab.haskell.org/ghc/ghc/-/blob/master/rts/linker/MachO.c#L651
    MachOSymbol* symbol = &oc->info->macho_symbols[ri->r_symbolnum];   // line 652
    if(symbol->nlist->n_type & N_EXT)
        value = (uint64_t)lookupDependentSymbol((char*)symbol->name, oc, NULL);
    // ...
}
case ARM64_RELOC_PAGE21:            // https://gitlab.haskell.org/ghc/ghc/-/blob/master/rts/linker/MachO.c#L689
case ARM64_RELOC_GOT_LOAD_PAGE21: {
    MachOSymbol* symbol = &oc->info->macho_symbols[ri->r_symbolnum];   // line 691
    // ...
}
case ARM64_RELOC_PAGEOFF12:         // https://gitlab.haskell.org/ghc/ghc/-/blob/master/rts/linker/MachO.c#L704
case ARM64_RELOC_GOT_LOAD_PAGEOFF12: {
    MachOSymbol* symbol = &oc->info->macho_symbols[ri->r_symbolnum];   // line 706
    // ...
}
```

When `r_extern == 0`, `r_symbolnum` is a **section ordinal** (1-based), not a symbol index.
Indexing `macho_symbols[section_ordinal]` reads a completely wrong symbol entry.
That wrong symbol's `name` may lack the leading `_` (e.g. a local symbol, debug symbol, or just a coincidentally-indexed entry), causing the `CHECK` to fire when [`lookupDependentSymbol`](https://gitlab.haskell.org/ghc/ghc/-/blob/master/rts/Linker.c#L872) falls through to `dlsym`.

There is also a **second latent bug** in [`findInternalGotRefs` at line 487](https://gitlab.haskell.org/ghc/ghc/-/blob/master/rts/linker/MachO.c#L487), which also never checks `r_extern`:

```c
// https://gitlab.haskell.org/ghc/ghc/-/blob/master/rts/linker/MachO.c#L497-L500
if (isGotLoad(ri)) {
    MachOSymbol* symbol = &oc->info->macho_symbols[ri->r_symbolnum];  // line 498 -- no r_extern check
    symbol->needs_got = true;
}
```

If a GOT relocation has `r_extern == 0`, this corrupts the wrong symbol's `needs_got` flag.

Summary of affected vs safe code paths:

| Code path | Checks `r_extern`? | Safe for `r_extern == 0`? |
|---|---|---|
| x86_64 [`relocateSection` GOT (L835)](https://gitlab.haskell.org/ghc/ghc/-/blob/master/rts/linker/MachO.c#L835) | [Yes (L845)](https://gitlab.haskell.org/ghc/ghc/-/blob/master/rts/linker/MachO.c#L845) | Yes (prints error) |
| x86_64 [`relocateSection` extern (L900)](https://gitlab.haskell.org/ghc/ghc/-/blob/master/rts/linker/MachO.c#L900) | Yes | N/A |
| x86_64 [`relocateSection` internal (L934)](https://gitlab.haskell.org/ghc/ghc/-/blob/master/rts/linker/MachO.c#L934) | Yes (implicit else) | [Yes (section ordinal, L951)](https://gitlab.haskell.org/ghc/ghc/-/blob/master/rts/linker/MachO.c#L951) |
| **aarch64 [`relocateSectionAarch64` (L584)](https://gitlab.haskell.org/ghc/ghc/-/blob/master/rts/linker/MachO.c#L584) all types** | **No** | **No -- BUG** |
| **aarch64 [`findInternalGotRefs` (L498)](https://gitlab.haskell.org/ghc/ghc/-/blob/master/rts/linker/MachO.c#L498)** | **No** | **No -- latent BUG** |
| [`resolveImports`](https://gitlab.haskell.org/ghc/ghc/-/blob/master/rts/linker/MachO.c#L221) | N/A (indirect sym table) | N/A |
| `ocResolve_MachO` GOT fill | N/A (iterates symbols) | N/A |

This explains why the bug is **aarch64-specific**: the x86_64 Mach-O path handles `r_extern == 0` correctly by design.
Loading many archives increases the probability of encountering an object file with `r_extern == 0` relocations (common in C code and optimised Haskell output), which triggers the misinterpretation.

### Path 2: Public C API does not add underscore prefix

The public C API [`lookupSymbol`](https://gitlab.haskell.org/ghc/ghc/-/blob/master/rts/Linker.c#L976) in `rts/Linker.c` (line 976) passes the label directly to `lookupDependentSymbol` without adding the platform's leading underscore.

The Haskell wrapper `GHCi.ObjLink.lookupSymbol` correctly uses `prefixUnderscore` before calling the C API.
But direct C/FFI callers (like this reproduction case) pass `"hs_process_map"` without underscore.

On Mach-O, `symhash` stores `_hs_process_map` (from the nlist table).
The lookup for `"hs_process_map"` fails, falls through to `dlsym`, and `CHECK('h' == '_')` fires.

This path may or may not be the trigger in this specific case (the crash could happen earlier during cascading resolution via Path 1), but it is a separate bug in the API: `lookupSymbol` should either document the underscore requirement or handle it internally.

## Platform

- **Architecture**: aarch64 (Apple Silicon, M-series)
- **OS**: macOS (darwin)
- **GHC versions tested**: 9.6.7, 9.12.2

Works on x86_64-linux, aarch64-linux, and x86_64-darwin.

## Expected behaviour

`resolveObjs` and `lookupSymbol` should either succeed or return a meaningful error (NULL / unresolved symbol name), not crash via `barf()`.

## Suggested fixes

### For Path 1 (primary fix): Add `r_extern` handling to aarch64 Mach-O relocations

In [`rts/linker/MachO.c`](https://gitlab.haskell.org/ghc/ghc/-/blob/master/rts/linker/MachO.c), [`relocateSectionAarch64`](https://gitlab.haskell.org/ghc/ghc/-/blob/master/rts/linker/MachO.c#L584) should check `ri->r_extern` before using `ri->r_symbolnum` as a symbol index, mirroring the x86_64 three-way dispatch in [`relocateSection` (lines 835-1012)](https://gitlab.haskell.org/ghc/ghc/-/blob/master/rts/linker/MachO.c#L835).
Each relocation type handler needs an `r_extern` guard:

```c
case ARM64_RELOC_UNSIGNED: {
    if (ri->r_extern) {
        MachOSymbol* symbol = &oc->info->macho_symbols[ri->r_symbolnum];
        uint64_t value = symbol_value(oc, symbol);
        // ... existing logic
    } else {
        // r_symbolnum is a 1-based section ordinal
        int targetSecNum = ri->r_symbolnum - 1;
        Section *targetSec = &oc->sections[targetSecNum];
        // compute relocated address from section base
    }
    break;
}
// Same pattern for ARM64_RELOC_BRANCH26, ARM64_RELOC_PAGE21, etc.
```

Similarly, [`findInternalGotRefs` (line 497)](https://gitlab.haskell.org/ghc/ghc/-/blob/master/rts/linker/MachO.c#L497) should guard the `r_extern` check:

```c
if (isGotLoad(ri) && ri->r_extern) {
    MachOSymbol* symbol = &oc->info->macho_symbols[ri->r_symbolnum];
    symbol->needs_got = true;
}
```

### For Path 2: Harden the `dlsym` fallback in `lookupDependentSymbol`

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

### For Path 2 (alternative): Add prefix in `lookupSymbol` C API

Make the public C API [`lookupSymbol`](https://gitlab.haskell.org/ghc/ghc/-/blob/master/rts/Linker.c#L976) match the Haskell wrapper's behaviour:

```c
void* lookupSymbol(const char* lbl) {
#if defined(LEADING_UNDERSCORE)
    // ... prepend '_' to lbl before lookup
#endif
    return lookupSymbol_(lbl);
}
```
