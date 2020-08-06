{
  # there's a regression introduced in
  # https://github.com/NixOS/nixpkgs/pull/91084 which prevents writable
  # directories from being created in makeLayeredImage so we lock to 20.03 to
  # avoid it
  inputs.nixpkgs.url = "github:nixos/nixpkgs/20.03";

  outputs = { self, nixpkgs }: {
    lib = {
      sources = import ./sources.nix { inherit (nixpkgs) lib; };

      # this does lock us to a different nixpkgs version for the docker build
      # steps but it ensures the API is what we expect
      docker = import ./docker.nix {
        pkgs = import nixpkgs { system = "x86_64-linux"; };
      };
    };
  };
}
