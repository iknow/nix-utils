{ lib
, nix
, closureInfo
, runCommand
, writeText
, writeReferencesToFile
, stdenv
, python3
}:

let
  inherit (builtins) head elem length toString;

  readMetadata = item:
    builtins.fromJSON (builtins.readFile "${item}/metadata.json");

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
      "etc/passwd" = {
        type = "file";
        text = concatLines (lib.mapAttrsToList makePasswdLine users);
      };
      "etc/group" = {
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
    "etc/nsswitch.conf" = {
      type = "file";
      text = "hosts: files dns";
    };
  }) // (lib.optionalAttrs tmp {
    "tmp" = {
      type = "directory";
      mode = "0777";
    };
  }) // (lib.optionalAttrs (usrBinEnv != null) {
    "usr/bin/env" = {
      type = "link";
      target = usrBinEnv;
    };
  }) // (lib.optionalAttrs (binSh != null) {
    "bin/sh" = {
      type = "link";
      target = binSh;
    };
  });

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
      "nix/var/nix" = {
        type = "directory";
        sources = [{
          path = store;
        }];
      };
    };

  /* Wraps a derivation such that including it in a layer only includes its
     dependencies
  */
  makeDependencyOnlyWrapper = drv:
    let
      referencesFile = writeReferencesToFile drv;
    in
    runCommand "${drv.name}-dependencies" {
      passthru.excludeFromLayer = true;
    } ''
      grep -v "${drv}" "${referencesFile}" > $out
    '';

  /* Creates a layer from entries without its dependencies

     This is mainly for internal use. See makeLayer for the structure of
     entries.
  */
  makeBareLayerFromEntries = {
    name,
    entries,
    umask
  }: runCommand name {
    nativeBuildInputs = [ python3 ];
    entriesJson = builtins.toJSON entries;
    passAsFile = [ "entriesJson" ];
    passthru.excludeFromLayer = true;
  } ''
    mkdir -p $out
    python ${./build-layer.py} $out ${umask} "$SOURCE_DATE_EPOCH" < $entriesJsonPath
    python ${./hash-layer.py} $out
  '';

  /* Creates a layer from an optional base tar file and include/excludes

     This is mainly for internal use. Prefer using makeLayer instead.
  */
  makeLayer' = {
    name,
    baseTar ? null,
    includes ? [],
    excludes ? [],
    passthru ? {}
  }:
    let
      includesFile = writeText "layer-includes" (builtins.concatStringsSep "\n" includes);
      excludesFile = writeText "layer-excludes" (builtins.concatStringsSep "\n" excludes);
      directExcludes = builtins.filter (x: x.excludeFromLayer or false) includes;
    in
    runCommand name {
      nativeBuildInputs = [ python3 ];
      layerIncludes = writeReferencesToFile includesFile;
      layerExcludes = writeReferencesToFile excludesFile;
      directExcludes = directExcludes ++ [ includesFile ];
      inherit baseTar;

      passthru = passthru // {
        inherit includes;

        # When building things layer by layer, we typically want to exclude all
        # previous layer's included dependencies. Specifying just
        # lastLayer.propagatedDependencies is easier instead of having to
        # combine all previous layer's includes.
        propagatedDependencies = includes ++ excludes;
      };
    } ''
      cp --no-preserve=mode $layerExcludes excludePaths

      # don't copy things we only use for deriving references
      for exclude in $directExcludes; do
        echo "$exclude" >> excludePaths
      done

      comm <(sort excludePaths) <(sort $layerIncludes) -1 -3 > pathsToCopy

      mkdir -p $out
      touch tarPaths
      if [ -n "$baseTar" ] && [ -f "$baseTar" ]; then
        cp --no-preserve=mode "$baseTar" "$out/layer.tar"
        tar tf "$baseTar" > tarPaths
      fi

      tar_with_opts() {
        tar rf $out/layer.tar \
          --sort=name \
          --mtime="@$SOURCE_DATE_EPOCH" \
          --owner=0:0 \
          --group=0:0 \
          --directory=/ \
          "$@"
      }

      entry_exists() {
        # strip leading /, all these paths are nix store entries which are
        # guaranteed to be absolute paths
        normalized_path=''${1:1}

        # the entries in the tar could possibly list the nix store as
        # "nix/store", "/nix/store" or "./nix/store"
        grep -qE "^(/|\./)?$normalized_path(/|$)" tarPaths
      }

      # initialize nix/store folders otherwise they're just "filled in" and
      # have the default owner/uid and mtime
      #
      # this doesn't really affect reproducibility but just makes the image
      # nicer
      if [ -s pathsToCopy ]; then
        if ! entry_exists "/nix"; then
          tar_with_opts --no-recursion --mode="0555" "./nix"
        fi
        if ! entry_exists "/nix/store"; then
          tar_with_opts --no-recursion --mode="0555" "./nix/store"
        fi
      fi

      # copy nix store paths
      while read item; do
        if entry_exists "$item"; then
          echo "== FAIL =="
          echo "Base tar already contains path $item"
          echo "Adding this path again can result in duplicate entries which makes this an invalid layer"
          echo "If this is intentional, add these paths in a different layer instead"
          echo
          exit 1
        fi
        echo "Adding $item to layer nix store"
        tar_with_opts ".$item"
      done < pathsToCopy

      # if we have an image after all this, hash it and build up the OCI blob
      # structure
      if [ -f $out/layer.tar ]; then
        python ${./hash-layer.py} $out
      fi
    '';

  /* Creates an OCI layer

     entries is an attrset describing files to create / copy into the layer.
     The attrset name will be the path of the entry, and the value is an
     attrset describing it.

     The entry attrset MUST have a type which is one of "file", "directory" or
     "link". "mode", "uid", "gid" may also be specified to change the file
     attributes where applicable.

     File entries may have either a text attr which writes the contents as is
     to the file, or a source attr which specifies a path to copy from.
     Directory entries can have a sources attr which is a list of paths to copy
     from. Each source is an attrset containing a path and uid, gid, and mode
     specifier (0755, +w, etc). Link entries must have a target attr specifying
     where to link to.

     umask specifies the "umask" to be applied to entries by default.

     path is a list of derivations to add to the PATH of the resulting image
     containing this layer.

     includes is a list of derivations to include into the layer's nix store.
     This is mostly useful for putting less frequently changing dependencies
     earlier in the layer list.

     excludes is a list of derivations whose closure should be excluded from
     the layer (in the case where those derivations are already included in an
     earlier layer).
  */
  makeLayer = {
    name,
    entries ? null,
    umask ? "0222",
    path ? [],
    includes ? [],
    excludes ? [],
  }:
    let
      # we build the bareLayer first so that we can include it in the closure
      # calculation, this ensures that any referenced store paths in entries is
      # included in the full layer
      #
      # this works because the tar isn't compressed and the references are
      # plainly visible
      bareLayer = lib.optionals (entries != null && entries != {}) [(
        makeBareLayerFromEntries {
          name = "${name}-bare";
          inherit entries umask;
        }
      )];

      fullIncludes = path ++ includes ++ bareLayer;
    in
    makeLayer' {
      inherit name excludes;

      baseTar = map (layer: "${layer}/layer.tar") bareLayer;

      includes = fullIncludes;

      passthru = {
        inherit path;
        bare = bareLayer;
      };
    };

  /* Creates an OCI image manifest and config

     architecture and os should be one of GOARCH and GOOS as listed in
     https://golang.org/doc/install/source#environment

     config is an attrset containing the image config as described in
     https://github.com/opencontainers/image-spec/blob/master/config.md#properties

     layers is a list of either layer configs or layer derivations. Layer
     configs will automatically have the previous layer added as excludes.

     Note that when providing layer derivations, making sure that paths are
     excluded correctly is left up to the user. Store paths could be duplicated
     across layers or dependent store paths might be missing.
  */
  makeImageManifest = {
    name,
    tag ? null,
    architecture,
    os,
    config ? null,
    layers ? []
  }@spec:
    let
      # the config itself may contain references that we need to include, so we
      # inject an additional layer to ensure we have everything
      configDependencies = (writeText "${name}-config" (builtins.toJSON config)) // {
        excludeFromLayer = true;
      };
      configLayer = lib.optionals (config != null) [{
        name = "${name}-entrypoint-layer";
        includes = [ configDependencies ];
      }];

      resolvedLayers = builtins.foldl' (acc: layer:
        let
          layerDerivation = makeLayer (layer // {
            # exclude the closures of all previous layers
            excludes = (layer.excludes or []) ++ (
              builtins.concatMap (layer: layer.includes or []) acc
            );
          });

          resolvedLayer = if (lib.isDerivation layer) then layer else layerDerivation;
        in
        acc ++ [ resolvedLayer ]
      ) [] (layers ++ configLayer);

      path = lib.makeBinPath (builtins.concatMap (layer: layer.path or []) resolvedLayers);

      # filter out empty layers, this can happen if a layer has no entries and
      # all its dependencies are excluded
      nonEmptyLayers = builtins.concatMap (layer:
        lib.optionals (builtins.pathExists "${layer}/layer.tar") [ layer ]
      ) resolvedLayers;

      nonEmptyLayersMetadata = map readMetadata nonEmptyLayers;

      # merge PATH in env
      configEnv = config.Env or [];
      newEnv =
        if (builtins.any (lib.hasPrefix "PATH=") configEnv) then
          map (env:
            if (lib.hasPrefix "PATH=" env) then
              builtins.replaceStrings ["$PATH"] [path] env
            else
              env
          ) configEnv
        else
          configEnv ++ [ "PATH=${path}" ];

      configJson = builtins.toJSON {
        inherit architecture os;
        created = "1970-01-01T00:00:00Z";
        rootfs = {
          type = "layers";
          diff_ids = map (metadata: metadata.digest) nonEmptyLayersMetadata;
        };
        config = (spec.config or {}) // {
          Env = newEnv;
        };
      };

      configHash = builtins.hashString "sha256" configJson;

      manifestJson = builtins.toJSON {
        schemaVersion = 2;
        config = {
          mediaType = "application/vnd.oci.image.config.v1+json";
          size = builtins.stringLength configJson;
          digest = "sha256:" + configHash;
        };
        layers = nonEmptyLayersMetadata;
      };

      manifestHash = builtins.hashString "sha256" manifestJson;

      metadataJson = builtins.toJSON ({
        mediaType = "application/vnd.oci.image.manifest.v1+json";
        size = builtins.stringLength manifestJson;
        digest = "sha256:" + manifestHash;
        platform = {
          inherit architecture os;
        };
      } // lib.optionalAttrs (tag != null) {
        annotations."org.opencontainers.image.ref.name" = tag;
      });
    in
    runCommand name {
      inherit configJson manifestJson metadataJson;
      passAsFile = [ "configJson" "manifestJson" "metadataJson "];

      passthru = {
        inherit spec resolvedLayers;
        layers = nonEmptyLayers;
      };
    } ''
      mkdir -p $out
      cp $configJsonPath $out/config.json
      cp $manifestJsonPath $out/manifest.json
      cp $metadataJsonPath $out/metadata.json

      mkdir -p $out/blobs/sha256
      ln -s $out/config.json $out/blobs/sha256/${configHash}
      ln -s $out/manifest.json $out/blobs/sha256/${manifestHash}
      ${lib.concatMapStringsSep "\n" (layer: ''
        cp -r ${layer}/blobs $out
      '') nonEmptyLayers}
    '';

  /* Creates an OCI image directory containing various manifests

     This is usable with skopeo using the path oci:<path to result>:tag

     Example:

       skopeo inspect --config oci:result

       skopeo copy oci:result:0.1.0 docker-daemon:myimage:0.1.0
  */
  makeImageDirectory = { name, manifests, passthru ? {} }:
    let
      indexJson = builtins.toJSON {
        schemaVersion = 2;
        manifests = map readMetadata manifests;
      };
    in
    runCommand name {
      inherit indexJson;
      passAsFile = [ "indexJson" ];
      passthru = passthru // {
        inherit manifests;
      };
    } ''
      mkdir -p $out
      echo '{"imageLayoutVersion":"1.0.0"}' > $out/oci-layout
      cp $indexJsonPath $out/index.json

      ${lib.concatMapStringsSep "\n" (manifest: ''
        cp -r ${manifest}/blobs $out
      '') manifests}
    '';

  /* Creates an OCI image directory containing only a single manifest

     This accepts the same arguments as makeImageManifest
  */
  makeSimpleImage = spec:
    let
      manifest = makeImageManifest spec;
    in
    makeImageDirectory {
      name = "${spec.name}-container";
      manifests = [ manifest ];
      passthru = {
        inherit manifest;
      };
    };
}
