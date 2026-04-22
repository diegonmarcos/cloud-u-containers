{
  description = "Hickory DNS — dist layout v2";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    container = builtins.fromJSON (builtins.readFile ./build-hickory-dns.json);

    engine = import ../../_shared/engine.nix;
    lib    = nixpkgs.lib;

    caddy_wg_ip = container.services.caddy.ip;
    zones       = buildJson.dns.zones;
    forwarders  = buildJson.dns.forwarders;
    dns_port    = buildJson.ports.dns;

    # Generated config fragments
    zoneBlocks = lib.concatMapStringsSep "\n\n" (suffix: ''
      [[zones]]
      zone = "${suffix}"
      zone_type = "Primary"
      file = "${suffix}.zone"
    '') zones;

    forwarderBlocks = lib.concatMapStringsSep "\n\n" (ns: ''
      [[zones.stores.name_servers]]
      ip = "${ns}"
      connections = [
        { protocol = { type = "udp" } },
        { protocol = { type = "tcp" } }
      ]
    '') forwarders;

    namedToml = ''
      listen_addrs_ipv4 = ["${caddy_wg_ip}"]
      listen_port = ${toString dns_port}
      directory = "/etc/zones"

      # ── Wildcard zones (catch-all → Caddy WG IP) ──
      ${zoneBlocks}

      # ── Root forwarder (everything else → declared upstream DNS) ──
      [[zones]]
      zone = "."
      zone_type = "External"

      [zones.stores]
      type = "forward"

      ${forwarderBlocks}
    '';

    mkZoneText = suffix: ''
      $ORIGIN ${suffix}.
      $TTL 60
      @    IN SOA  hickory-dns.${suffix}. admin.${suffix}. 1 3600 900 604800 60
      @    IN NS   hickory-dns.${suffix}.
      @    IN A    ${caddy_wg_ip}
      *    IN A    ${caddy_wg_ip}
    '';

    # Template list: named.toml + one zone file per declared suffix under zones/
    templates =
      [ { name = "named.toml"; text = namedToml; } ]
      ++ (map (s: { name = "zones/${s}.zone"; text = mkZoneText s; }) zones);

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = engine {
        inherit pkgs buildJson container templates;
        srcDir = ./.;
        composeSpec = import ./compose.nix { inherit buildJson container; };
        title = "Hickory DNS";
      };
    });
  };
}
