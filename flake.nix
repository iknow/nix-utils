{
  outputs = { self, nixpkgs }: {
    lib = {
      sources = import ./sources.nix { inherit (nixpkgs) lib; };
    };
  };
}
