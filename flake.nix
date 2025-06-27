{
  description = "Nostr Client in Elixir";

  inputs = {
    nixpkgs.url = github:NixOS/nixpkgs/nixos-25.05;
  };

  outputs = { self, nixpkgs }: let
    overlay = prev: final: rec {
      erlang = prev.beam.interpreters.erlang_27;
      beamPackages = prev.beam.packagesWith erlang;
      elixir = beamPackages.elixir_1_18;
      hex = beamPackages.hex;
    };

    forAllSystems = nixpkgs.lib.genAttrs [
      "x86_64-linux"
      "aarch64-linux"
      #"x86_64-darwin"
      #"aarch64-darwin"
    ];

    nixpkgsFor = system:
      import nixpkgs {
        inherit system;
        overlays = [overlay];
      };
    in {
    devShells = forAllSystems (system: let
      pkgs = nixpkgsFor system;
    in {
      default = pkgs.callPackage ./shell.nix {};
    });
  };
}

