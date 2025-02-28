{
  description = "(a description of your package goes here)";

  inputs = {
    nixpkgs.url = github:NixOS/nixpkgs/nixos-24.11;
  };

  outputs = {
    self,
    nixpkgs,
    ...
  }: let
    overlay = prev: final: rec {
      beamPackages = prev.beam.packagesWith prev.beam.interpreters.erlang_27;
      elixir = beamPackages.elixir_1_17;
      erlang = final.erlang_27;
      hex = final.beamPackages.hex;
    };

    forAllSystems = nixpkgs.lib.genAttrs [
      "x86_64-linux"
      "aarch64-linux"
    ];

    nixpkgsFor = system:
      import nixpkgs {
        inherit system;
        overlays = [overlay];
      };
  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgsFor system;
      mixNixDeps = import ./deps.nix {
        lib = pkgs.lib;
        beamPackages = pkgs.beamPackages;
      };
    in rec {
      nostrbase = pkgs.callPackage ./default.nix {inherit mixNixDeps;};
      default = nostrbase;
    });
    devShells = forAllSystems (system: let
      pkgs = nixpkgsFor system;
    in {
      default = pkgs.callPackage ./shell.nix {};
    });
  };
}
