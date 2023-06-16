{
  inputs.flake-utils.url = "github:numtide/flake-utils";
  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        inherit (pkgs) callPackage;
      in
      {
        # this does lock us to a different nixpkgs version for the docker build
        # steps but it ensures the API is what we expect
        lib.docker = callPackage ./docker.nix {};
        utils.oci = callPackage ./oci {};
      }
    ) // {
      # this is system agnostic
      sources = import ./sources.nix { inherit (nixpkgs) lib; };
    };
}
