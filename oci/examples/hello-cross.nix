{ pkgs ? import <nixpkgs> {
  crossSystem = "aarch64-linux";
} }:

with pkgs.callPackage ./.. {};

makeSimpleImage {
  name = "hello-image";
  tag = "0.1.0";
  config = {
    Entrypoint = [ "${pkgs.hello}/bin/hello" ];
  };
}
