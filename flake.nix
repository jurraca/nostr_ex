{
  description = "(a description of your package goes here)";

  inputs = {
    nixpkgs.url = github:NixOS/nixpkgs/nixos-23.11;
    flake-utils.url = github:numtide/flake-utils;
  };

  outputs = { self, nixpkgs, flake-utils }:
    # build for each default system of flake-utils: ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"]
    flake-utils.lib.eachDefaultSystem (system:
      let
        beamPackages = pkgs.beam.packagesWith pkgs.beam.interpreters.erlang_26;
        overlay = final: prev: {
	    beamPackages = beamPackages;
	    elixir = final.beamPackages.elixir_1_16;
	    hex = final.beamPackages.hex.overrideAttrs {
		buildInputs = [ final.elixir ];
	    };
            rebar3 = final.beamPackages.rebar3;
	    mix2nix = prev.mix2nix.overrideAttrs {
                buildInputs = [ final.beamPackages.erlang ];
	    };
        };
        # Declare pkgs for the specific target system we're building for.
        pkgs = import nixpkgs {
	    inherit system ;
	    overlays = [overlay];
	};
        # Import a development shell we'll declare in `shell.nix`.
        devShell = import ./shell.nix { inherit pkgs ; };

        nostrbase = let
            lib = pkgs.lib;
            # FIXME: Import the Mix deps into Nix by running
            # mix2nix > nix/deps.nix
             mixNixDeps = import ./deps.nix {inherit lib beamPackages;};
          in beamPackages.mixRelease {
            pname = "nostrbase";
            # Elixir app source path
            src = ./.;
            version = "0.1.0";

            # FIXME: mixNixDeps was specified in the FIXME above. Uncomment the next line.
             inherit mixNixDeps;

            # Add other inputs to the build if you need to
            buildInputs = [ pkgs.elixir ];
          };
      in
      {
        devShells.default = devShell;
        packages.default = nostrbase;
      }
    );
}

