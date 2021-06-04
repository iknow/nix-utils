{ pkgs ? import <nixpkgs> {} }:

with pkgs.callPackage ./.. {};

makeSimpleImage {
  name = "hello-image";
  tag = "0.1.0";
  architecture = "amd64";
  os = "linux";
  config = {
    Entrypoint = [ "${pkgs.hello}/bin/hello" ];
  };
}
