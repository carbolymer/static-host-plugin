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
    iohkNix = {
      url = "github:input-output-hk/iohk-nix";
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
    defaultCompiler = "ghc967";
    windowsCompilerNixName = "ghc9122";
  in
    inputs.flake-utils.lib.eachSystem supportedSystems (
      system: let
        nixpkgs = import inputs.nixpkgs {
          overlays = [
            inputs.haskellNix.overlay
            inputs.iohkNix.overlays.haskell-nix-extra
          ];
          inherit system;
          inherit (inputs.haskellNix) config;
        };
        inherit (nixpkgs) lib;

        # Make /usr/bin/security available in PATH (needed on darwin for certificate access)
        macOS-security =
          nixpkgs.writeScriptBin "security" ''exec /usr/bin/security "$@"'';

        haskellBuildUtils = nixpkgs.haskellBuildUtils.override {
          compiler-nix-name = defaultCompiler;
          index-state = "2024-12-24T12:56:48Z";
        };

        # Fetch proto-lens with submodules and fix symlinks for plan and build phases
        protoLensSrc = nixpkgs.fetchgit {
          url = "https://github.com/google/proto-lens";
          rev = "9b41fe0e10e8fe12ec508a3b361d0f0c2217c491";
          sha256 = "sha256-ruTbbUKVJBPANnm6puigtp26mmiVDd0jMpLfJLOuUpU=";
          fetchSubmodules = true;
        };
        fixProtoLensSrc = nixpkgs.runCommand "proto-lens-fixed" {} ''
          mkdir -p $out
          cp -a ${protoLensSrc}/. $out/
          chmod -R +w $out
          # Fix proto-lens-imports symlink in proto-lens
          rm -rf $out/proto-lens/proto-lens-imports/google
          cp -r ${protoLensSrc}/google/protobuf/src/google $out/proto-lens/proto-lens-imports/
          # Fix proto-src symlink in proto-lens-protobuf-types
          rm -rf $out/proto-lens-protobuf-types/proto-src
          cp -r ${protoLensSrc}/google/protobuf/src $out/proto-lens-protobuf-types/proto-src
          chmod -R -w $out
        '';

        cabalProject = nixpkgs.haskell-nix.cabalProject' ({config, ...}: {
          src = ./.;
          name = "static-dylib";
          compiler-nix-name = defaultCompiler;

          inputMap = {
            "https://github.com/google/proto-lens/9b41fe0e10e8fe12ec508a3b361d0f0c2217c491" = protoLensSrc;
          };

          crossPlatforms = p:
            lib.optionals (system == "x86_64-linux") [
              p.musl64
            ];

          shell = {
            tools.cabal = "3.16.1.0";
            withHoogle = false;
            crossPlatforms = _: [];
            nativeBuildInputs = lib.optionals nixpkgs.stdenv.hostPlatform.isDarwin [
              macOS-security
            ];
          };

          # Override proto-lens source to use fixed symlinks (inputMap provides the fixed
          # source for plan computation; this module provides it for the build phase)
          modules = [
            ({lib, pkgs, config, ...}: let
              protoLensPackages = [
                "proto-lens"
                "proto-lens-arbitrary"
                "proto-lens-discrimination"
                "proto-lens-optparse"
                "proto-lens-protobuf-types"
                "proto-lens-protoc"
                "proto-lens-runtime"
                "proto-lens-setup"
                "proto-lens-tests-dep"
                "proto-lens-tests"
                "discrimination-ieee754"
                "proto-lens-benchmarks"
              ];
            in {
              packages =
                lib.genAttrs
                (builtins.filter (p: config.packages ? ${p}) protoLensPackages)
                (p:
                  {src = lib.mkForce (fixProtoLensSrc + "/${p}");}
                  // lib.optionalAttrs (p == "proto-lens-protobuf-types") {
                    components.library.build-tools = [pkgs.buildPackages.protobuf];
                  });
            })
          ];
        });

        flake = cabalProject.flake {};

        gitrev = inputs.self.rev or "0000000000000000000000000000000000000000";

        myexeRaw = cabalProject.hsPkgs.myexe.components.exes.myexe;
        # Patch git revision into the executable binary
        myexe = nixpkgs.buildPackages.runCommand myexeRaw.name ({
          inherit (myexeRaw) exeName meta passthru;
          nativeBuildInputs = [haskellBuildUtils]
            ++ lib.optionals nixpkgs.stdenv.hostPlatform.isDarwin [nixpkgs.darwin.signingUtils];
        }) (''
          mkdir -p $out
          cp --no-preserve=timestamps --recursive ${myexeRaw}/* $out/
          chmod -R +w $out/bin
          set-git-rev "${gitrev}" $out/bin/*
        '' + lib.optionalString nixpkgs.stdenv.hostPlatform.isDarwin ''
          for exe in $out/bin/*; do
            signIfRequired "$exe"
          done
        '');
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

          if grep -q "Processed 4 entries" stdout.txt; then
            echo "PASS: dynamic .o loading with StablePtr Map succeeded" | tee $out
            echo "--- full output ---"
            cat stdout.txt
          else
            echo "FAIL: unexpected output:"
            cat stdout.txt
            exit 1
          fi
        '';

        # Portable binary release (rewrite-libs on macOS for nix-store-independent distribution)
        myexeRelease = nixpkgs.runCommand "myexe-release" {
          nativeBuildInputs = [haskellBuildUtils]
            ++ lib.optionals nixpkgs.stdenv.hostPlatform.isDarwin [nixpkgs.bintools];
        } ''
          mkdir -p $out/bin
          cp ${myexe}/bin/* $out/bin/
          chmod -R +w $out/bin
          ${lib.optionalString nixpkgs.stdenv.hostPlatform.isDarwin ''
            rewrite-libs $out/bin ${myexe}/bin/*
          ''}
        '';

        # Cross-compilation checks: verify the packages build
        # Windows cross-compilation uses ghc9122 (via appendModule), matching cardano-node
        windowsProject = (cabalProject.appendModule {compiler-nix-name = lib.mkForce windowsCompilerNixName;}).projectCross.mingwW64;
        crossChecks = lib.optionalAttrs (system == "x86_64-linux") {
          cross-mingwW64-mylib = windowsProject.hsPkgs.mylib.components.library;
          cross-mingwW64-myexe = windowsProject.hsPkgs.myexe.components.exes.myexe;
          cross-musl64-mylib = cabalProject.projectCross.musl64.hsPkgs.mylib.components.library;
          cross-musl64-myexe = cabalProject.projectCross.musl64.hsPkgs.myexe.components.exes.myexe;
        };
      in
        lib.recursiveUpdate flake {
          project = cabalProject;
          checks =
            {
              dynamic-load = dynamicLoadCheck;
              release = myexeRelease;
            }
            // crossChecks;
          packages = {
            mylib-bundle = mylibBundle;
            myexe-release = myexeRelease;
          };
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
