{ pkgs ? import <nixpkgs> {} }:

with pkgs.callPackage ./.. {};

rec {
  # Building layers separately is generally useful if the layers are
  # independent. Nothing in the baseLayer needs to be excluded in the other
  # layers so depsLayer doesn't need to depend on baseLayer
  baseLayer = makeLayer {
    name = "base-layer";
    entries = makeFilesystem {
      # root account automatically added
      accounts = {};
      hosts = true;
      tmp = true;
      usrBinEnv = "/bin/env";
    } // {
      "/" = {
        type = "directory";
        sources = [{
          # Generally, it's preferrable to keep packages in the nix/store as
          # they tend to reference themselves and you end up including them
          # twice in the layer. But it is possible to copy them directly onto
          # the root if necessary.
          path = pkgs.pkgsStatic.busybox;
        }];
      };
    };

    # busybox has references to itself but we don't really need them
    excludes = [ pkgs.pkgsStatic.busybox ];
  };

  depsLayer = makeLayer {
    name = "deps-layer";

    # include all dependencies of nix but not nix itself
    includes = [ (makeDependencyOnlyWrapper pkgs.nix) ];
  };

  nixLayer = makeLayer {
    name = "nix-layer";
    path = [ pkgs.nix ];

    # adds nix to the nix store state
    entries = makeNixStoreEntries "nix-store" [ pkgs.nix ];
    excludes = depsLayer.propagatedDependencies;
  };

  image = makeSimpleImage {
    name = "manual-layers-image";
    tag = "0.1.0";
    architecture = "amd64";
    os = "linux";
    config = {
      Env = [ "PATH=/bin:$PATH" ];
      Cmd = [
        "nix-instantiate"
        # with this option, the command fails if nix is not in the store state
        "--option" "restrict-eval" "true"
        "--eval"
        "--expr" "null"
      ];
    };
    layers = [
      baseLayer
      depsLayer
      nixLayer
    ];
  };
}
