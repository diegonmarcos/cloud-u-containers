{
  description = "Gitea — self-hosted Git service (dist layout v2, Type B wrap-upstream)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # ── Data sources (declarative JSON) ────────────────────────────
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    container = builtins.fromJSON (builtins.readFile ./build-gitea.json);

    engine = import ../../_shared/engine.nix;
    lib    = nixpkgs.lib;

    # ── init-mirrors.sh data — the logic lives in the template ───
    # This used to pre-render ~60 lines of bash PER repo inside nix strings,
    # which nothing could run without nixpkgs, so no test ever exercised it —
    # and the shipped script counted 13 empty private mirrors as healthy.
    # Nix now emits only data (one function call per repo); converge_mirror /
    # remove_excluded in templates/init-mirrors.sh.tpl hold the behaviour, and
    # test-init-mirrors.ts runs that template against a stub gitea.
    giteaConfig    = buildJson.gitea;
    org            = giteaConfig.org;
    mirrors        = container.gitea.mirrors;
    # Read from build.json directly (not from the derived container json):
    # the deriver consumes `exclude` to omit repos from gitea.mirrors, so by
    # the time it reaches build-gitea.json the excluded names are gone.
    excludeNames   = giteaConfig.mirror_policy.exclude or [];
    q              = lib.escapeShellArg;
    mirrorBlock    = lib.concatMapStringsSep "\n"
      (name: "converge_mirror ${q name} ${q mirrors.${name}.upstream} ${
        if mirrors.${name}.private or false then "true" else "false"}")
      (builtins.attrNames mirrors);
    excludeBlock   = lib.concatMapStringsSep "\n"
      (n: "remove_excluded ${q n}") excludeNames;

    initMirrorsVars = {
      PORT_HTTP       = toString buildJson.ports.app;
      CONTAINER_NAME  = buildJson.containers.app.container_name;
      ORG             = org;
      MIRROR_INTERVAL = giteaConfig.mirror_interval;
      EXCLUDE_NAMES   = lib.concatStringsSep " " excludeNames;
      EXCLUDE_BLOCK   = excludeBlock;
      MIRROR_BLOCK    = mirrorBlock;
    };

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = engine {
        inherit pkgs buildJson container;
        srcDir = ./.;
        templates = [
          { name = "init-mirrors.sh"; vars = initMirrorsVars; }
          { name = "gate.Caddyfile"; text = import ./gate.nix buildJson; }
        ];
        composeSpec = import ./compose.nix { inherit buildJson container; };
        title = "Gitea — self-hosted Git service";
      };
    });
  };
}
