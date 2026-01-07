{ lib
, nix
, closureInfo
, runCommand
, writeText
, writeClosure
, python3
, pigz
, jq
, buildPackages
}:

let
  entries = import ./entries.nix { inherit lib nix closureInfo runCommand; };

  defaultOs = buildPackages.go.GOOS;
  defaultArchitecture = buildPackages.go.GOARCH;
in

entries // rec {
  /* Wraps a derivation such that including it in a layer only includes its
     dependencies
  */
  makeDependencyOnlyWrapper = drv:
    let
      referencesFile = writeClosure [ drv ];
    in
    runCommand "${drv.name}-dependencies" {
      passthru.excludeFromLayer = true;
    } ''
      grep -v "${drv}" "${referencesFile}" > $out
    '';

  /* Creates a layer from an optional base tar file, entries and includes

     This is mainly for internal use. Prefer using makeLayer instead.

     baseTar can be any tar file. See makeLayer for the description of entries,
     umask, mtime, includes and excludes.

     In terms of precedence, baseTar > entries > includes. Files / directories
     from a "higher" level are never overwritten (in terms of both content and
     file attributes).

     Duplicate files will print a warning but directories will be skipped
     silently.
  */
  makeLayer' = {
    name,
    baseTar ? null,
    entries ? {},
    umask ? "0222",
    mtime ? null,
    includes ? [],
    excludes ? [],
    format ? "gzip"
  }:
    let
      directExcludes = builtins.filter (x: x.excludeFromLayer or false) includes;
    in
    runCommand name {
      nativeBuildInputs = [ python3 pigz ];
      layerIncludes = writeClosure includes;
      layerExcludes = writeClosure excludes;
      inherit baseTar format directExcludes;

      entriesJson = builtins.toJSON entries;
      passAsFile = [ "entriesJson" ];

      passthru = {
        inherit includes;
        excludeFromLayer = true;

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

      mkdir -p $out
      if [ -n "$baseTar" ] && [ -f "$baseTar" ]; then
        cp --no-preserve=mode "$baseTar" "$out/layer.tar"
      fi

      python ${./build-layer.py} \
        --out $out/layer.tar \
        --umask ${umask} \
        --mtime ${if mtime == null then "$SOURCE_DATE_EPOCH" else (builtins.toString mtime)} \
        --entries $entriesJsonPath \
        --includes $layerIncludes \
        --excludes excludePaths

      # if we have an image after all this, hash it and build up the OCI blob
      # structure
      if [ -f $out/layer.tar ]; then
        sha256sum $out/layer.tar | cut -b -64 > $out/contentsha256
        case $format in
          gzip) pigz -3 -n -m $out/layer.tar ;;
          tar)  ;;
          *) echo "Unsupported format: '$format'"; exit 1 ;;
        esac
        python ${./hash-layer.py} $out $format
      fi
    '';

  /* Creates an OCI layer

     entries is an attrset describing files to create / copy into the layer.
     The attrset name will be the absolute path of the entry, and the value is
     an attrset describing it.

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

     mtime specifies the mtime as a unix timestamp (in seconds) for all files
     in this layer. By default, it will use "$SOURCE_DATE_EPOCH" to match
     dockerTools.

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
    mtime ? null,
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
        makeLayer' {
          name = "${name}-bare";
          inherit entries umask mtime;
          format = "tar";
        }
      )];

      fullIncludes = path ++ includes ++ bareLayer;
    in
    makeLayer' {
      inherit name mtime excludes;

      baseTar = builtins.foldl' (_: x: x) null (map (layer: "${layer}/layer.tar") bareLayer);

      includes = fullIncludes;
    } // {
      inherit path;
      bare = bareLayer;
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
    tag ? "",
    architecture ? defaultArchitecture,
    os ? defaultOs,
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

      # we want PATH defined in later layers to take priority over earlier
      # layers so we have to reverse the list
      path = lib.makeBinPath (builtins.concatMap (layer: layer.path or []) (lib.reverseList resolvedLayers));

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

      configJson = (writeText "${name}-config" (builtins.toJSON ((spec.config or {}) // {
        Env = newEnv;
      })));
    in
    runCommand name {
      nativeBuildInputs = [ python3 ];
      layers = resolvedLayers;
      passthru = {
        inherit spec;
        layers = resolvedLayers;
      };
    } ''
      mkdir -p $out

      python ${./build-image-manifest.py} \
        --out $out \
        --config ${configJson} \
        --tag "${tag}" \
        --architecture "${architecture}" \
        --os "${os}" \
        $layers
    '';

  /* Creates an OCI image directory containing various manifests

     This is usable with skopeo using the path oci:<path to result>:tag

     Example:

       skopeo inspect --config oci:result

       skopeo copy oci:result:0.1.0 docker-daemon:myimage:0.1.0
  */
  makeImageDirectory = { name, manifests, passthru ? {} }:
    runCommand name {
      inherit manifests;
      nativeBuildInputs = [ jq ];
      passthru = {
        inherit manifests;
        imageFormat = "oci";
      };
    } ''
      mkdir -p $out
      echo '{"imageLayoutVersion":"1.0.0"}' > $out/oci-layout
      for manifest in $manifests; do
        cat "$manifest/metadata.json"
      done | jq -cs '{ schemaVersion: 2, manifests: . }' > $out/index.json

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
    } // {
      inherit manifest;
    };
}
