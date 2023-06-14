{
  inputs.flake-utils.url = "github:numtide/flake-utils";
  outputs = { self, nixpkgs, flake-utils }: 
  flake-utils.lib.eachDefaultSystem (system: 
    {
    lib = {
      sources = import ./sources.nix { inherit (nixpkgs) lib; };

      # this does lock us to a different nixpkgs version for the docker build
      # steps but it ensures the API is what we expect
      docker = import ./docker.nix {
        pkgs = import nixpkgs {inherit system;};
      };
    };
    utils.oci = (import nixpkgs { inherit system; }).callPackage ./oci {};
  });
}
