# Consequences of Dynamic .o Loading via the RTS Linker

## Overview

This design loads compiled Haskell `.o`/`.a` files at runtime into a running executable using GHC's RTS linker (`initLinker_`, `loadObj`, `loadArchive`, `resolveObjs`, `lookupSymbol`).
The loaded code shares the same address space, GHC runtime, and heap as the host executable.
This document analyses the implications.

## Single GHC Runtime

There is exactly **one GHC runtime** in the process.
The loaded `.o` code does not bring its own RTS -- it links against the RTS already present in `myexe`.
This means:

- One set of RTS flags (`+RTS ... -RTS`)
- One I/O manager
- One thread scheduler
- One stable pointer table
- One set of `MVar`/`TVar` primitives

The loaded code is indistinguishable from statically linked code once symbols are resolved.

## Garbage Collection

There is exactly **one garbage collector**.
Both `myexe` and `mylib` code allocate on the same GHC heap.
The GC treats all live objects identically regardless of which `.o` they originated from.

### Data from myexe shared to mylib

When `myexe` creates any Haskell value -- a `Map`, a record, a list, an algebraic data type, an `IORef`, an `MVar`, or any other heap object -- and passes a `StablePtr` to `mylib`, the value lives on the GHC heap owned by `myexe`'s allocation.
The `StablePtr` pins the value -- the GC will not collect it while the `StablePtr` exists.
Once `mylib` dereferences the `StablePtr`, it obtains a normal Haskell reference to the original value, with its full type structure intact.
If `mylib` retains this reference (e.g. stores it in an `IORef` or `TVar`), the GC keeps it alive through the normal reachability rules.
All constituent parts of the value -- nested data constructors, thunks, `Text` chunks, `ByteString` buffers, `Map` nodes, list cells -- remain on the shared heap.
No copying, serialisation, or marshalling occurs.
This applies equally to simple types like `Int` and to complex structures like `Map (Set Text) [Vector Double]`.

### Data from mylib shared to myexe

Symmetrically, any data allocated by `mylib` lives in one of two places:
- **GHC heap** (for Haskell values of any type) -- managed by the single GC, no different from data allocated by `myexe`
- **C heap** (for explicitly `malloc`'d memory, e.g. `CString` via `newCString`) -- must be freed by the caller with `free`

If `mylib` returns a `StablePtr` back to `myexe`, the same zero-copy sharing applies in reverse.
`myexe` dereferences it and obtains a normal Haskell reference to whatever type `mylib` allocated -- records, maps, mutable references, or any other Haskell value.

There is no distinction between "myexe's data" and "mylib's data" at the GC level.
They are all objects on the same heap with the same GC policies.

## Long-Running Process Scenario

Consider `myexe` running as a long-lived server that loads `mylib` at some later point.

### Before loading

`myexe` runs normally.
The RTS linker is initialised but idle.
The heap contains only objects from `myexe`'s own code.

### During loading

`loadArchive`/`loadObj` map the object code into the process address space.
`resolveObjs` patches symbol references.
This is a stop-the-world operation with respect to the loaded code (the rest of `myexe` continues running if loading happens on a different Haskell thread, but the loaded code is not callable until `resolveObjs` completes).

### After loading

The loaded code behaves identically to statically linked code.
GC pauses may increase because the heap is now larger (more live objects from `mylib`'s libraries).

### Unloading

`unloadObj` can unload a previously loaded `.o`.
However, this is **unsafe** if any live Haskell closures reference code or data from the unloaded object.
The GC does not track which heap objects point into which object code.
Unloading while references exist leads to segfaults.
In practice, unloading is only safe when you can guarantee no live references remain -- which is difficult in a lazy language with thunks.

## Memory Usage

### Code segment

Each loaded `.a`/`.o` maps its code into the process address space.
On x86_64, the RTS linker allocates loaded object code in the low 2 GB by default (required for 32-bit relocations in position-dependent code); the GC heap is not subject to this constraint.
This can be a constraint if many large archives are loaded.
The `+RTS -xp` flag changes this to use `mmap` at arbitrary addresses, but the loaded code must be compiled with `-fPIC -fexternal-dynamic-refs`.

### Heap

The GHC heap is shared.
Loading `mylib` does not duplicate any data structures -- whether `Text` buffers, `Map` trees, `Vector` arrays, records, or thunks -- there is a single copy of each value.
Passing a `StablePtr` is zero-copy; it is literally a pointer into the existing heap.
This holds for values of any Haskell type, not just specific containers.

### Compared to separate processes

If `mylib` were a separate process (e.g. communicating via IPC), every data exchange would require serialisation/deserialisation and copying.
The shared-heap design avoids this entirely at the cost of shared failure domains (a crash in `mylib` code crashes the whole process).

## Sockets, Network, File Handles

There is **no difference** from normal statically linked code.
The loaded `mylib` code uses the same I/O manager, the same file descriptor table, and the same network stack as `myexe`.

- Sockets opened by `mylib` are visible to `myexe` and vice versa
- `mylib` can read/write `MVar`s, `TVar`s, and `IORef`s created by `myexe`
- Async exceptions can be thrown between threads regardless of which `.o` they originate from
- Signal handlers are process-global

This is a consequence of sharing one RTS: there is no isolation boundary.

## Limitations

### Type safety is the caller's responsibility

The FFI boundary (`foreign export`/`foreign import ccall "dynamic"`) erases Haskell types.
If `myexe` looks up `hs_process_map` and casts the pointer to the wrong function signature, the result is undefined behaviour.
There is no runtime type checking at the `lookupSymbol` boundary.

### ABI coupling

The loaded `.o` files must be compiled with the **exact same GHC version** and the **exact same versions of all dependencies** as the host executable.
A mismatch in package versions (e.g. `text-2.1.2` vs `text-2.1.1`) means different symbol names (the unit-id is part of the Z-encoded symbol), leading to unresolved symbols.
A mismatch in GHC versions means different RTS calling conventions, leading to crashes.

### No isolation

A bug in loaded code (infinite loop, memory leak, segfault) affects the entire process.
There is no sandboxing.

### Boot library loading

The RTS linker's symbol table does not automatically contain symbols from statically linked libraries in the executable.
All dependency archives (including GHC boot libraries like `base`, `ghc-internal`, `text`, `containers`) must be explicitly loaded via `loadArchive` before the target `.o` so that `resolveObjs` can find them.
The `rts` archive must **not** be loaded (it conflicts with the already-running RTS).

### Platform differences

- **x86_64-linux**: The RTS linker uses `mmap` for code and resolves ELF relocations.
  Works reliably.
  This is the primary development and CI platform.
- **aarch64-linux**: The RTS linker resolves ELF relocations for AArch64.
  ARM64 uses different relocation types (e.g. `R_AARCH64_CALL26`, `R_AARCH64_ADR_PREL_PG_HI21`) which the RTS linker handles.
  The low-2GB address space restriction does not apply on AArch64 -- ARM64 code uses PC-relative addressing with wider ranges.
- **x86_64-darwin**: The RTS linker handles Mach-O.
  Generally works but Apple's code signing restrictions may require entitlements for mapping writable-then-executable memory.
- **aarch64-darwin** (Apple Silicon): The RTS linker handles Mach-O for ARM64.
  Apple Silicon enforces W^X (write-or-execute, never both) at the hardware level.
  The RTS linker must use `pthread_jit_write_protect_np` to toggle between writable and executable pages.
  Hardened runtime entitlements (`com.apple.security.cs.allow-jit`) may be required.
- **x86_64-windows** (cross-compiled via mingwW64): The RTS linker handles PE/COFF.
  Works but the low-2GB address space constraint is tighter on Windows.
  The `+RTS -xp` flag can relax this if code is compiled with `-fPIC -fexternal-dynamic-refs`.
