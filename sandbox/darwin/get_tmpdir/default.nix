{ stdenv, lib }:

stdenv.mkDerivation {
  name = "get_tmpdir";

  src = lib.sourceByRegex ./. [
    "Makefile"
    ".*\.m"
  ];

  installPhase = ''
    mkdir -p $out/bin
    mv get_tmpdir $out/bin
  '';
}
