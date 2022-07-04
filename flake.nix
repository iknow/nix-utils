{
  outputs = { self, nixpkgs }: {
    lib = {
      sources = import ./sources.nix { inherit (nixpkgs) lib; };

      # this does lock us to a different nixpkgs version for the docker build
      # steps but it ensures the API is what we expect
      docker = import ./docker.nix {
        pkgs = import nixpkgs { system = "x86_64-linux"; };
      };
    };
    utils.x86_64-linux.oci = (import nixpkgs { system = "x86_64-linux"; }).callPackage ./oci {};
  };
}
