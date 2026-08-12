{
  description = "DBGate — Universal database manager — dist layout v2 (flake as orchestrator)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # ── Data sources (declarative JSON) ────────────────────────────
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    container = builtins.fromJSON (builtins.readFile ./build-dbgate.json);
    # 2026-04-27 migrated: cloud-data-databases.json → _cloud-data-consolidated.json (databases derived from .services[].containers[].db_engine)
    # _cloud-data-consolidated.json resolution:
    #   1. /app/_cloud-data-consolidated.json        — bundled in-image
    #   2. ../../../1_cicd/dist/...               — dev: cloud repo dist/
    #   3. ../../../cloud-data/...                   — legacy: c3_git_repos clone
    #   4. ../../../_cloud-data-consolidated.json    — legacy: cloud repo root
    consolidatedPath =
      if builtins.pathExists /app/_cloud-data-consolidated.json
        then /app/_cloud-data-consolidated.json
      else if builtins.pathExists ../../../1_cloud-configs/dist/_cloud-data-consolidated.json
        then ../../../1_cloud-configs/dist/_cloud-data-consolidated.json
      else if builtins.pathExists ../../../cloud-data/_cloud-data-consolidated.json
        then ../../../cloud-data/_cloud-data-consolidated.json
      else ../../../_cloud-data-consolidated.json;
    consolidated = builtins.fromJSON (builtins.readFile consolidatedPath);

    # Derive the database list (same shape as the deprecated split file — migrated 2026-04-27) from
    # consolidated.services[].containers[*] entries that declare db_engine.
    nixLib = nixpkgs.lib;
    deriveDatabases = let
      services = consolidated.services or {};
      vms = consolidated.vms or {};
      svcEntries = nixLib.mapAttrsToList (svcName: svc: {
        name = svcName;
        value = svc;
      }) services;
      mkDb = svcName: svc: cKey: c:
        let
          vmId = svc.vm or null;
          vm = if vmId != null && vms ? ${vmId} then vms.${vmId} else {};
        in {
          service = svcName;
          container = c.container_name or (svcName + "_" + cKey);
          container_key = cKey;
          type = c.db_engine;
          enabled = svc.enabled or true;
          vm = vmId;
          vm_alias = vm.ssh_alias or null;
          wg_ip = vm.wg_ip or null;
          image = c.image or null;
          port = c.port or null;
          dns = c.dns or null;
          user = c.db_user or null;
          db = c.db_name or null;
          healthcheck = c.healthcheck or null;
          volumes = c.volumes or [];
          resources = c.resources or null;
          backup = c.backup or false;
        };
      perService = svcEntries: nixLib.concatLists (map (e:
        let
          containers = e.value.containers or {};
          containerEntries = nixLib.mapAttrsToList (k: v: { name = k; value = v; }) containers;
        in
          map (ce: mkDb e.name e.value ce.name ce.value)
            (builtins.filter (ce: (ce.value.db_engine or null) != null) containerEntries)
      ) svcEntries);
    in
      perService svcEntries;
    dbData = { databases = deriveDatabases; };

    engine = import ../../_shared/engine.nix;

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      lib  = pkgs.lib;
    in {
      default = engine {
        inherit pkgs buildJson container;
        srcDir = ./.;
        templates = [];
        composeSpec = import ./compose.nix {
          inherit lib buildJson container dbData;
        };
        title = "DBGate — Universal Database Manager";
      };
    });
  };
}
