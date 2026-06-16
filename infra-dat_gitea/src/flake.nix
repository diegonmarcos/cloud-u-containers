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

    # ── Mirror block — pre-rendered bash for init-mirrors.sh ─────
    giteaConfig   = buildJson.gitea;
    mirrorInterval = giteaConfig.mirror_interval;
    org           = giteaConfig.org;
    mirrors       = giteaConfig.mirrors;
    mirrorNames   = builtins.attrNames mirrors;
    mirrorEntries = map (name: {
      inherit name;
      upstream = mirrors.${name}.upstream;
      private  = mirrors.${name}.private or false;
    }) mirrorNames;

    mkMirrorEntry = m: ''
      if ! api "$API/repos/${org}/${m.name}" >/dev/null 2>&1; then
        echo "Creating mirror: ${org}/${m.name} <- ${m.upstream}"
        api -X POST "$API/repos/migrate" -d '{
          "clone_addr": "${m.upstream}",
          "repo_name": "${m.name}",
          "repo_owner": "${org}",
          "mirror": true,
          "mirror_interval": "${mirrorInterval}",
          "private": ${if m.private then "true" else "false"},
          "service": "github"
        }' >/dev/null && echo "  OK ${m.name}" || echo "  FAIL ${m.name}"
      else
        echo "EXISTS ${org}/${m.name}"
      fi
    '';
    mirrorBlock = lib.concatMapStringsSep "\n" mkMirrorEntry mirrorEntries;

    initMirrorsVars = {
      PORT_HTTP      = toString buildJson.ports.app;
      CONTAINER_NAME = buildJson.containers.app.container_name;
      ORG            = org;
      MIRROR_BLOCK   = mirrorBlock;
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
        ];
        composeSpec = import ./compose.nix { inherit buildJson container; };
        title = "Gitea — self-hosted Git service";
      };
    });
  };
}
