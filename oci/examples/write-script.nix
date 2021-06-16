{ pkgs ? import <nixpkgs> {} }:

with pkgs.callPackage ./.. {};

makeSimpleImage {
  name = "write-script-image";
  config = {
    Entrypoint = [(pkgs.writeScript "entrypoint.sh" ''
      #!${pkgs.stdenv.shell}
      echo "Hello from script"
    '')];
  };
}
