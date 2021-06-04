{ pkgs ? import <nixpkgs> {} }:

with pkgs.callPackage ./.. {};

makeSimpleImage {
  name = "hello-image";
  tag = "0.1.0";
  architecture = "amd64";
  os = "linux";
  config = {
    User = "nobody";
    Entrypoint = [ "/entrypoint.sh" ];
  };
  layers = [
    {
      name = "base-layer";
      path = [
        pkgs.busybox
      ];
      entries = makeFilesystem {
        accounts = {
          users.root = {
            extraGroups = [ "nobody" ]; # this is optional
            home = "/home/root";
          };
          users.nobody = {
            uid = 999;
            group = "nobody";
            home = "/home/nobody";
            shell = "/bin/sh";
          };
          groups.nobody = {
            gid = 999;
          };
        };
        hosts = true;
        tmp = true;
        usrBinEnv = "${pkgs.busybox}/bin/env";
        binSh = "${pkgs.busybox}/bin/sh";
      };
    }
    {
      # This layer will only contain hello, but not glibc since it's included
      # in the previous layer
      name = "hello-layer";
      path = [ pkgs.hello ];
    }
    {
      # There's no real reason to separate the entrypoint into its own layer
      # aside from separating things that change frequently from those that
      # don't to minimize build times. Proper layer separation also helps
      # ensure that layers stay cached in the registry / nodes.
      name = "entrypoint-layer";
      entries."entrypoint.sh" = {
        type = "file";
        mode = "0755";
        # since we use bash here, this will implicitly include it in this layer
        text = ''
          #!${pkgs.bash}/bin/bash
          hello -g "Hello $(whoami) running bash $BASH_VERSION"
        '';
      };
    }
  ];
}
