{ pkgs ? import <nixpkgs> {
  crossSystem = "aarch64-linux";
} }:

with pkgs.callPackage ./.. {};

makeSimpleImage {
  name = "hello-image";
  tag = "0.1.0";
  architecture = "arm64";
  os = "linux";
  config = {
    Entrypoint = [ "${pkgs.hello}/bin/hello" ];
  };
}
