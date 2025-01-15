{ lib }:

{
  sourceByPattern = src: { include ? [], exclude ? [] }:
    let
      # This transforms a path like `foo/bar/baz` into [
      #   "foo"
      #   "foo/bar"
      #   "foo/bar/baz"
      # ]
      #
      # A path with a trailing slash like `foo/` will be made into [
      #   "foo"
      #   "foo/.*"
      # ]
      buildPathList = path: builtins.foldl'
        (acc: elem:
          if !builtins.isString elem then
            acc
          else if acc == [] then
            acc ++ [ elem ]
          else if elem == "" then
            acc ++ [ "${lib.last acc}/.*" ]
          else
            acc ++ [ "${lib.last acc}/${elem}" ]
        )
        []
        (lib.splitString "/" path);

      # To include a path, it and all its parent directories must be accepted by the filter
      makeIncludeRegex = path: map (elem: "^${elem}$") (buildPathList path);

      # To exclude a path, we must exclude only the path itself
      makeExcludeRegex = path: [ "^${lib.removeSuffix "/" path}$" ];

      includeRegexes = lib.unique (builtins.concatMap makeIncludeRegex include);
      excludeRegexes = lib.unique (builtins.concatMap makeExcludeRegex exclude);
    in
    builtins.path {
      name = "source";
      path = src;
      filter = (path: type:
        let
          relPath = lib.removePrefix (toString src + "/") (toString path);
          matchRelPath = re: builtins.match re relPath != null;
        in
        (lib.any matchRelPath includeRegexes) && !(lib.any matchRelPath excludeRegexes));
    };
}
