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
    };
    nixpkgs.follows = "haskellNix/nixpkgs-unstable";
    flake-utils.url = "github:hamishmack/flake-utils/hkm/nested-hydraJobs";
  };

  outputs = inputs: let
    supportedSystems = [
      "x86_64-linux"
      "x86_64-darwin"
      "aarch64-linux"
      "aarch64-darwin"
    ];

    defaultCompiler = "ghc9122";
    crossCompilerVersionMusl = "ghc967";
  in
    inputs.flake-utils.lib.eachSystem supportedSystems (
      system: let
        nixpkgs = import inputs.nixpkgs {
          overlays = [
            inputs.haskellNix.overlay
          ];
          inherit system;
          inherit (inputs.haskellNix) config;
        };
        inherit (nixpkgs) lib;

        cabalProject = nixpkgs.haskell-nix.cabalProject' ({config, ...}: {
          src = ./.;
          name = "static-dylib";
          compiler-nix-name = lib.mkDefault defaultCompiler;

          crossPlatforms = p:
            lib.optionals (system == "x86_64-linux" && config.compiler-nix-name == crossCompilerVersionMusl)
            [
              p.aarch64-multiplatform-musl
              p.musl64
            ];

          shell = {
            tools = {
              cabal = "3.16.1.0";
            };
            withHoogle = false;
            crossPlatforms = _: [];
          };

          modules = [];
        });

        flake = cabalProject.flake (
          lib.optionalAttrs (system == "x86_64-linux") {
            variants = lib.genAttrs [crossCompilerVersionMusl] (compiler-nix-name: {
              inherit compiler-nix-name;
            });
          }
        );
      in
        lib.recursiveUpdate flake {
          project = cabalProject;
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
