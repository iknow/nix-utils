{ lib, nix, closureInfo, runCommand }:

let
  inherit (builtins) elem toString;

  makeAccounts = spec:
    let
      users = {
        root = {
          uid = 0;
          group = "root";
          home = "/root";
          shell = "/bin/sh";
        } // (spec.users.root or {});
      } // (builtins.removeAttrs (spec.users or {}) [ "root" ]);

      groups = {
        root.gid = 0;
      } // (spec.groups or {});

      groupsForUser = { group, extraGroups ? [], ... }: [ group ] ++ extraGroups;

      usersForGroup = group: builtins.concatStringsSep "," (
        builtins.concatMap
          (name: lib.optionals (elem group (groupsForUser users.${name})) [ name ])
          (builtins.attrNames users)
      );

      makeGroupLine = name: { gid, ... }:
        "${name}:x:${toString gid}:${usersForGroup name}";

      makePasswdLine = name: { uid, home, group, shell, ... }:
        "${name}:x:${toString uid}:${toString groups.${group}.gid}::${home}:${shell}";

      makeHome = name: { uid, group, home, ... }: {
        name = home;
        value = {
          type = "directory";
          uid = uid;
          gid = groups.${group}.gid;
          mode = "0755";
        };
      };

      concatLines = builtins.concatStringsSep "\n";
    in

    {
      "/etc/passwd" = {
        type = "file";
        text = concatLines (lib.mapAttrsToList makePasswdLine users);
      };
      "/etc/group" = {
        type = "file";
        text = concatLines (lib.mapAttrsToList makeGroupLine groups);
      };
    } // (builtins.listToAttrs (lib.mapAttrsToList makeHome users));
in
rec {
  /* Creates entries for a bare minimum file system with various options

     accounts is an attrset containing users and groups similar to nixos
     users.users and users.groups. null means no accounts will be created.
     A root user and group will be created by default. The root user can be
     modified by adding your own entry for it. Home directories for all users
     will also be created.

     hosts accepts a boolean to enable support for hosts files

     tmp accepts a boolean to create a tmp directory at /tmp

     usrBinEnv and binSh accept paths to be links to /usr/bin/env and /bin/sh
     respectively

     Note that these don't compose so a later entries layer will overwrite
     account information.

     Example:

       makeFilesystem {
         accounts = {
           users.root = {
             home = "/home/root";
             extraGroups = [ "nobody" ];
           };
           users.nobody = {
             uid = "999";
             group = "nobody";
             home = "/home/nobody";
             shell = "/bin/sh";
           };
           groups.nobody = {
             gid = "999";
           };
         };
         hosts = true;
         tmp = true;
         usrBinEnv = "${pkgs.busybox}/bin/env";
         binSh = "${pkgs.busybox}/bin/sh";
       }

     This will create an entries file setting up 2 users, root and nobody. It
     also sets up hosts resolution, /tmp and links for /bin/sh and
     /usr/bin/env.
  */
  makeFilesystem = {
    accounts ? null,
    hosts ? false,
    tmp ? false,
    usrBinEnv ? null,
    binSh ? null,
  }:
  (lib.optionalAttrs (accounts != null) (
    makeAccounts accounts
  )) // (lib.optionalAttrs hosts {
    "/etc/nsswitch.conf" = {
      type = "file";
      text = "hosts: files dns";
    };
  }) // (lib.optionalAttrs tmp {
    "/tmp" = {
      type = "directory";
      mode = "1777";
    };
  }) // (lib.optionalAttrs (usrBinEnv != null) {
    "/usr/bin/env" = {
      type = "link";
      target = usrBinEnv;
    };
  }) // (lib.optionalAttrs (binSh != null) {
    "/bin/sh" = {
      type = "link";
      target = binSh;
    };
  });

  /* Gets the uid and primary gid of a user

     This is primarily useful for building up entry files and ensuring that
     ownership is consistent with the accounts
  */
  getUidGid = accounts: user:
    let
      uid = accounts.users.${user}.uid;
      group = accounts.users.${user}.group;
      gid = accounts.groups.${group}.gid;
    in
    { inherit uid gid; };

  /* Creates user-writable directory entries

     accounts matches the specification in makeFilesystem

     user is the user who will own the directories. The group will be the
     user's primary group.

     dirs is a list of directories to create
  */
  makeUserDirectoryEntries = accounts: user: dirs:
    let
      entry = {
        type = "directory";
        mode = "0755";
      } // getUidGid accounts user;
    in
    lib.genAttrs dirs (_: entry);

  /* Creates entries setting up a nix store state that includes closure

     This is normally only needed if you need to run nix inside the container.
  */
  makeNixStoreEntries = name: closure:
    let
      info = closureInfo { rootPaths = closure; };
      store = runCommand "${name}-store" {
        nativeBuildInputs = [ nix ];
      } ''
        export NIX_STATE_DIR=$out
        nix-store --load-db < ${info}/registration
        rm $out/gcroots/profiles
        rm $out/db/reserved
      '';
    in
    {
      "/nix/var/nix" = {
        type = "directory";
        sources = [{
          path = store;
        }];
      };
    };
}
