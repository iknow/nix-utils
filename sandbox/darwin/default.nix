{ pkgs }:

package: { profile, sourceRoot, stateDir ? null }:

let
  inherit (pkgs) lib;
  homeDir = builtins.getEnv "HOME";

  get_tmpdir = pkgs.callPackage ./get_tmpdir {};

  cfg = (lib.evalModules {
    modules = [ ./options.nix ] ++ lib.filter lib.pathExists [ (homeDir + "/.config/eikaiwa/sandbox.nix") ];
  }).config.eikaiwa.sandbox;

  common' = pkgs.runCommand "common.sb" {} ''
    substitute "${./common.sb}" "$out" \
      --subst-var-by helpers "$(< ${./helpers.sb})"
  '';

  profile' = pkgs.runCommand  "${baseNameOf profile}" {} ''
    substitute "${profile}" "$out" \
      --subst-var-by common "${common'}" \
      --subst-var-by helpers "$(< ${./helpers.sb})"
  '';

  composedProfile = pkgs.writeText "composed-${baseNameOf profile}" ''
    ;; Project Policy
    (import "${profile'}")

    ;; Extra User Rules
    ${cfg.extraRules}
  '';

  sandboxed =  pkgs.stdenv.mkDerivation {
    name = "sandboxed-${package.name}";

    buildCommand = ''
      mkdir $out $out/bin
      wrap() {
        local wrapper=$out/bin/$(basename "$1")

        substitute ${./wrapper.sh} "$wrapper" \
          --subst-var-by "profile" "${composedProfile}" \
          --subst-var-by "command" "$1" \
          --subst-var-by "store_dir" "${builtins.storeDir}" \
          --subst-var-by "source_root" "${toString sourceRoot}" \
          --subst-var-by "get_tmpdir" "${get_tmpdir}/bin/get_tmpdir" \
          --subst-var-by "state_dir" '${toString stateDir}'

        chmod a+x "$wrapper"
      }

      for i in ${package}/bin/*; do
        wrap "$i"
      done
    '';
  };
in

if cfg.enable then sandboxed else package
