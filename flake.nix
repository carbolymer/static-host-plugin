{
  description = "static-dylib";

  inputs = {
    hackageNix = {
      url = "github:input-output-hk/hackage.nix";
      flake = false;
    };
    haskellNix = {
      url = "github:input-output-hk/haskell.nix";
      inputs.hackage.follows = "hackageNix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixpkgs.url = "github:NixOS/nixpkgs/11cb3517b3af6af300dd6c055aeda73c9bf52c48";
    flake-utils.url = "github:hamishmack/flake-utils/hkm/nested-hydraJobs";
  };

  outputs = inputs: let
    supportedSystems = [
      "x86_64-linux"
      "x86_64-darwin"
      "aarch64-linux"
      "aarch64-darwin"
    ];
    compiler = "ghc9122";
  in
    inputs.flake-utils.lib.eachSystem supportedSystems (
      system: let
        nixpkgs = import inputs.nixpkgs {
          overlays = [inputs.haskellNix.overlay];
          inherit system;
          inherit (inputs.haskellNix) config;
        };
        inherit (nixpkgs) lib;

        cabalProject = nixpkgs.haskell-nix.cabalProject' ({config, ...}: {
          src = ./.;
          name = "static-dylib";
          compiler-nix-name = compiler;

          crossPlatforms = p:
            lib.optionals (system == "x86_64-linux") [
              p.mingwW64
              p.musl64
            ];

          shell = {
            tools.cabal = "3.16.1.0";
            withHoogle = false;
            crossPlatforms = _: [];
          };

          modules = [];
        });

        flake = cabalProject.flake {};

        myexe = cabalProject.hsPkgs.myexe.components.exes.myexe;
        mylib = cabalProject.hsPkgs.mylib.components.library;
        ghcPkg = cabalProject.pkg-set.config.ghc.package;

        # Bundle: collect all of mylib's dependency .a archives into a single directory.
        # Includes both GHC boot libraries and haskell.nix-built deps.
        mylibBundle = nixpkgs.runCommand "mylib-bundle" {
          __structuredAttrs = true;
          exportReferencesGraph.closure = [mylib ghcPkg];
        } ''
          set -euo pipefail
          mkdir -p $out

          # Collect all Haskell .a archives from mylib's closure, skip rts
          cat .attrs.json | ${nixpkgs.jq}/bin/jq -r '.closure[].path' \
          | while read -r p; do
              find "$p" -name 'libHS*.a' \
                ! -name '*_p.a' ! -name '*_debug.a' ! -name '*_thr*' \
                ! -path '*/rts-*' 2>/dev/null || true
            done | sort -u | while read -r a; do
              # Copy with a unique name derived from the store path
              base=$(basename "$a")
              hash=$(echo "$a" | cut -d/ -f4 | cut -c1-8)
              cp "$a" "$out/''${hash}-''${base}"
            done
        '';

        # Native check: load all archives from the bundle directory,
        # then verify dynamic calling with StablePtr Map works.
        dynamicLoadCheck = nixpkgs.runCommand "dynamic-load-check" {} ''
          set -euo pipefail

          ARCHIVES=$(find ${mylibBundle} -name '*.a' | sort)
          ${myexe}/bin/myexe $ARCHIVES > stdout.txt 2>&1 || {
            echo "myexe failed:"
            cat stdout.txt
            exit 1
          }

          if grep -q "Processed 3 entries" stdout.txt; then
            echo "PASS: dynamic .o loading with StablePtr Map succeeded" | tee $out
            echo "--- full output ---"
            cat stdout.txt
          else
            echo "FAIL: unexpected output:"
            cat stdout.txt
            exit 1
          fi
        '';

        # Cross-compilation checks: verify the packages build
        crossChecks = lib.optionalAttrs (system == "x86_64-linux") {
          cross-mingwW64-mylib = cabalProject.projectCross.mingwW64.hsPkgs.mylib.components.library;
          cross-mingwW64-myexe = cabalProject.projectCross.mingwW64.hsPkgs.myexe.components.exes.myexe;
          cross-musl64-mylib = cabalProject.projectCross.musl64.hsPkgs.mylib.components.library;
          cross-musl64-myexe = cabalProject.projectCross.musl64.hsPkgs.myexe.components.exes.myexe;
        };
      in
        lib.recursiveUpdate flake {
          project = cabalProject;
          checks =
            {dynamic-load = dynamicLoadCheck;}
            // crossChecks;
          packages.mylib-bundle = mylibBundle;
          legacyPackages = {
            inherit cabalProject nixpkgs;
          };
          formatter = nixpkgs.alejandra;
        }
    );

  nixConfig = {
    extra-substituters = [
      "https://cache.iog.io"
    ];
    extra-trusted-public-keys = [
      "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="
    ];
    allow-import-from-derivation = true;
  };
}
