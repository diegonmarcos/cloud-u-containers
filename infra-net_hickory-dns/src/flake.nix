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
    # IPv6 mirror of caddy_wg_ip (wg0 ULA fd0c:1d00::1). When set, every zone
    # gets apex + wildcard AAAA alongside its A records, so mesh clients prefer
    # IPv6 via Happy Eyeballs and fall back to IPv4 on failure — which is what
    # makes the v4 mesh 10.0.0.0/24 colliding with a hotel/home LAN survivable
    # instead of fatal. Null (field absent) ⇒ v4-only zones, exactly as before.
    caddy_wg_ipv6 = buildJson.dns.caddy_wg_ipv6 or null;
    zones       = buildJson.dns.zones;
    forwarders  = buildJson.dns.forwarders;
    dns_port    = buildJson.ports.dns;
    # Per-zone specific records (e.g. mail/maddy → oci-mail WG IP) emitted
    # before the wildcard so they override the catch-all. Empty default
    # keeps zones with no overrides as pure wildcard.
    records     = buildJson.dns.records or {};

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
      # wg0 mesh ULA — serve DNS over IPv6 too (fd0c:1d00::1). Bind "::" (all v6)
      # not the specific ULA, so a not-yet-up wg0 addr can't crash-loop the resolver.
      # gcp-proxy has no public IPv6, so this is reachable only over wg0.
      listen_addrs_ipv6 = ["::"]
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

    # Build the zone file via explicit string concatenation rather than a
    # Nix `''` multi-line string. The `''` syntax's common-leading-
    # whitespace stripping interacts badly with `${...}` interpolations
    # that emit embedded newlines — leaving stray indent in front of the
    # `$ORIGIN` / `$TTL` directives, which Hickory rejects with
    # `UnexpectedToken(Origin)` (zone directives must start at column 0).
    # Plain "..." + "..." gives us exact control over every byte of
    # output regardless of source indentation.
    mkZoneText = suffix:
      let
        zoneRecords = records.${suffix} or [];
        recordBlock = lib.concatMapStrings (r:
          "${r.name}  IN ${r.type}  ${r.value}\n"
        ) zoneRecords;
      in
        "$ORIGIN ${suffix}.\n"
        + "$TTL 60\n"
        + "@    IN SOA  hickory-dns.${suffix}. admin.${suffix}. 1 3600 900 604800 60\n"
        + "@    IN NS   hickory-dns.${suffix}.\n"
        + "@    IN A    ${caddy_wg_ip}\n"
        + lib.optionalString (caddy_wg_ipv6 != null) "@    IN AAAA ${caddy_wg_ipv6}\n"
        + recordBlock
        + "*    IN A    ${caddy_wg_ip}\n"
        + lib.optionalString (caddy_wg_ipv6 != null) "*    IN AAAA ${caddy_wg_ipv6}\n";

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
