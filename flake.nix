{
  inputs.flake-utils.url = "github:numtide/flake-utils";
  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        inherit (pkgs) callPackage;
      in
      {
        lib = {
          sources = callPackage ./sources.nix {};
          # this does lock us to a different nixpkgs version for the docker build
          # steps but it ensures the API is what we expect
          docker = callPackage ./docker.nix {};
        };
        utils.oci = callPackage ./oci {};
      }
    );
}
