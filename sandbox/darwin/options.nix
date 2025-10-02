{ lib, ... }:

{
  options = {
    eikaiwa.sandbox = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };

      extraRules = lib.mkOption {
        type = lib.types.lines;
        default = "";
      };
    };
  };
}
