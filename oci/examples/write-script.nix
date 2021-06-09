{ pkgs ? import <nixpkgs> {} }:

with pkgs.callPackage ./.. {};

makeSimpleImage {
  name = "write-script-image";
  architecture = "amd64";
  os = "linux";
  config = {
    Entrypoint = [(pkgs.writeScript "entrypoint.sh" ''
      #!${pkgs.stdenv.shell}
      echo "Hello from script"
    '')];
  };
}
