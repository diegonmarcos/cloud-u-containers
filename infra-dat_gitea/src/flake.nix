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
    mirrors       = container.gitea.mirrors;
    mirrorNames   = builtins.attrNames mirrors;
    mirrorEntries = map (name: {
      inherit name;
      upstream = mirrors.${name}.upstream;
      private  = mirrors.${name}.private or false;
    }) mirrorNames;

    # PRIVATE repos need a GitHub auth_token in the migrate payload — anonymous
    # clone of a private repo yields a bare (empty) mirror. The token is read
    # at RUNTIME from $GITHUB_MIRROR_TOKEN (bash env), sourced from the
    # GITHUB_MIRROR_TOKEN key in a_solutions/infra-dat_gitea/src/secrets.yaml
    # (sops-encrypted, same dotenv pipeline as GITEA_ADMIN_*). That key does
    # NOT exist yet — nobody has generated the fine-grained GitHub PAT. Until
    # it does, private mirrors degrade to the same anonymous-clone behaviour
    # as before (empty mirror) but now WARN per-repo so the gap is visible in
    # init-mirrors output instead of silently swallowed.
    mkMirrorEntry = m: let
      privateStr = if m.private then "true" else "false";
    in ''
      if ! api "$API/repos/${org}/${m.name}" >/dev/null 2>&1; then
        echo "Creating mirror: ${org}/${m.name} <- ${m.upstream}"
        AUTH_JSON="{}"
        if [ "${privateStr}" = "true" ] && [ -n "''${GITHUB_MIRROR_TOKEN:-}" ]; then
          AUTH_JSON=$(jq -n --arg t "$GITHUB_MIRROR_TOKEN" '{auth_token:$t}')
        elif [ "${privateStr}" = "true" ]; then
          echo "  WARN: ${m.name} is private and GITHUB_MIRROR_TOKEN is not set -- anonymous clone yields an EMPTY mirror. Populate the GITHUB_MIRROR_TOKEN key in a_solutions/infra-dat_gitea/src/secrets.yaml (sops) with a fine-grained GitHub PAT (repo:read) to fix."
        fi
        PAYLOAD=$(jq -n \
          --arg clone_addr "${m.upstream}" \
          --arg repo_name "${m.name}" \
          --arg repo_owner "${org}" \
          --arg mirror_interval "${mirrorInterval}" \
          --argjson private ${privateStr} \
          --argjson auth "$AUTH_JSON" \
          '{clone_addr:$clone_addr, repo_name:$repo_name, repo_owner:$repo_owner, mirror:true, mirror_interval:$mirror_interval, private:$private, service:"github"} + $auth')
        api -X POST "$API/repos/migrate" -d "$PAYLOAD" >/dev/null && echo "  OK ${m.name}" || echo "  FAIL ${m.name}"
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
