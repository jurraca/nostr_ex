{
  pkgs,
  lib,
  beamPackages,
  elixir,
  mixNixDeps,
}:
beamPackages.mixRelease {
  pname = "nostrbase";
  src = ./.;
  version = "0.1.0";
  inherit mixNixDeps;

  # Add other inputs to the build if you need to
  buildInputs = [pkgs.elixir];
}
