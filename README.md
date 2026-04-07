# static-dylib

Demonstrates dynamic `.o` loading via GHC's RTS linker.
`myexe` loads `mylib` and its dependencies at runtime, passes Haskell data through `StablePtr`, and calls foreign-exported functions -- all sharing a single GHC runtime and heap.

## Running checks

Run the native dynamic-load test for your platform:

```bash
nix build path:.#checks.x86_64-linux.dynamic-load
nix build path:.#checks.aarch64-linux.dynamic-load
nix build path:.#checks.aarch64-darwin.dynamic-load
nix build path:.#checks.x86_64-darwin.dynamic-load
```

Release check (verifies git revision patching and macOS library rewriting):

```bash
nix build path:.#checks.x86_64-linux.release
nix build path:.#checks.aarch64-darwin.release
```

Cross-compilation checks (x86_64-linux only):

```bash
nix build path:.#checks.x86_64-linux.cross-mingwW64-mylib
nix build path:.#checks.x86_64-linux.cross-mingwW64-myexe
nix build path:.#checks.x86_64-linux.cross-musl64-mylib
nix build path:.#checks.x86_64-linux.cross-musl64-myexe
```

Run all checks at once:

```bash
nix flake check path:.
```

## Redistributable binaries

Build the release binary and mylib dependency bundle:

```bash
nix build path:.#myexe-release path:.#mylib-bundle
```

Copy them to a target directory:

```bash
mkdir -p dist
cp result/bin/myexe dist/
cp -r result-1/* dist/lib/
```

Run outside the nix store:

```bash
dist/myexe dist/lib/*.a
```

The `myexe` binary has the git revision patched in (via `set-git-rev`).
On macOS, `myexe-release` also rewrites dynamic library paths so the binary runs without nix.

Both `myexe` and the `.a` archives in `mylib-bundle` must come from the same build.
The loaded archives must match the exact GHC version and dependency versions compiled into `myexe`, otherwise symbol resolution will fail.

## Building the dependency bundle

```bash
nix build path:.#mylib-bundle
```

This produces a directory containing all `.a` archives needed to load `mylib` at runtime.

## Development shell

```bash
nix develop path:.
```
