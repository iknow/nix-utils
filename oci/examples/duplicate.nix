{ pkgs ? import <nixpkgs> {} }:

with pkgs.callPackage ./.. {};

let
  staticDerivation = builtins.toFile "test.sh" "";
in

{
  case1 = makeLayer' {
    name = "test-layer";
    baseTar = ./duplicate.tar;
    includes = [ staticDerivation ];
  };

  case2 = makeLayer' {
    name = "test-layer";
    baseTar = ./duplicate-absolute.tar;
    includes = [ staticDerivation ];
  };

  case3 = makeLayer {
    name = "test-layer";
    entries = {
      "${builtins.unsafeDiscardStringContext pkgs.hello}" = {
        type = "directory";
        sources = [{
          path = pkgs.hello;
        }];
      };
    };
    includes = [ pkgs.hello ];
  };
}
