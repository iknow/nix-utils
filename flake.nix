{
  inputs.flake-utils.url = "github:numtide/flake-utils";
  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        inherit (pkgs) callPackage;
      in
      {
        utils.docker = callPackage ./docker.nix {};
        utils.oci = callPackage ./oci {};
      }
    ) // {
      # this is system agnostic
      lib.sources = import ./sources.nix { inherit (nixpkgs) lib; };
    };
}
