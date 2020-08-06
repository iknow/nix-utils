{ pkgs }:
let
  inherit (pkgs) lib dockerTools stdenv runCommand;

  uid = "999";
  gid = "999";
  user = "deploy";
  group = "deploy";
  home = "/data";
in

{
  baseImage = dockerTools.buildImage {
    name = "base-image";
    tag = "latest";

    runAsRoot = ''
      #!${stdenv.shell}
      set -e

      ${dockerTools.shadowSetup}
      groupadd -r "${group}"
      useradd -r -g "${group}" -d "${home}" -M "${user}"
      mkdir -p "${home}"
      chown -R "${user}:${group}" "${home}"

      # setup a tmp directory
      mkdir -m 1777 /tmp

      # unconfigured nsswitch seems to ignore files
      echo 'hosts: files dns' > /etc/nsswitch.conf
    '';
  };

  makeLayeredImage = layeredImageOptions: dockerTools.buildLayeredImage (layeredImageOptions // {
    contents = [(runCommand "base-setup" {} ''
      mkdir -p $out/etc
      echo "root:x:0:0::/root:/bin/sh" > $out/etc/passwd
      echo "root:x:0:" > $out/etc/group

      echo "${user}:x:${uid}:${gid}::${home}:/bin/sh" >> $out/etc/passwd
      echo "${group}:x:${gid}:${user}" >> $out/etc/group

      # setup /usr/bin/env
      mkdir -p $out/usr/bin
      ln -s /bin/env $out/usr/bin/env

      # unconfigured nsswitch seems to ignore files
      echo 'hosts: files dns' > $out/etc/nsswitch.conf
    '')] ++ (layeredImageOptions.contents or []);

    config = {
      User = "deploy";
    } // (layeredImageOptions.config or {});

    extraCommands = ''
      # setup a tmp directory
      mkdir -m 1777 tmp

      # setup home directory
      # this runs inside a runCommand so we can't change ownership
      mkdir -m 1777 -p ".${home}"
    '' + (layeredImageOptions.extraCommands or "");
  });
}
