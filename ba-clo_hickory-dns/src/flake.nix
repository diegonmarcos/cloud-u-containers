{
  description = "Hickory DNS - Internal DNS server for WireGuard mesh (per-service .app zones)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {};

    title = "Hickory DNS";
    docker = import ../../_shared/docker.nix;

    # DNS suffix for service resolution
    suffix = "app";

    # ── Service registry (single source of truth) ──────────────────────
    # Each entry becomes a per-service zone: <name>.app → WG IP
    # Per-service zones mean unknown .app names fall through to the root
    # forwarder (Cloudflare) — no TLD hijacking.
    services = {
      # ── gcp-proxy (10.0.0.1) ──
      caddy            = { ip = "10.0.0.1"; desc = "Reverse proxy"; };
      authelia         = { ip = "10.0.0.1"; desc = "Authelia 2FA"; };
      introspect-proxy = { ip = "10.0.0.1"; desc = "OIDC introspect sidecar"; };
      vaultwarden      = { ip = "10.0.0.1"; desc = "Vaultwarden"; };
      ntfy             = { ip = "10.0.0.1"; desc = "Push notifications"; };
      hickory-dns      = { ip = "10.0.0.1"; desc = "Hickory DNS"; };

      # ── oci-apps (10.0.0.6) ──
      c3-api           = { ip = "10.0.0.6"; desc = "C3 Cloud Control Center API"; };
      c3-services      = { ip = "10.0.0.6"; desc = "C3 Unified Service API Gateway"; };
      c3-spec          = { ip = "10.0.0.6"; desc = "C3 OpenAPI spec server"; };
      c3-mcp           = { ip = "10.0.0.6"; desc = "C3 MCP server"; };
      c3-services-mcp  = { ip = "10.0.0.6"; desc = "C3 Services MCP server"; };
      mattermost-mcp   = { ip = "10.0.0.6"; desc = "Mattermost MCP server"; };
      mailu-mcp        = { ip = "10.0.0.6"; desc = "Mailu MCP server"; };
      g-workspace-mcp  = { ip = "10.0.0.6"; desc = "Google Workspace MCP server"; };
      crawlee          = { ip = "10.0.0.6"; desc = "Crawlee API"; };
      crawlee-ui       = { ip = "10.0.0.6"; desc = "Crawlee UI"; };
      radicale         = { ip = "10.0.0.6"; desc = "Radicale CalDAV/CardDAV"; };
      mattermost       = { ip = "10.0.0.6"; desc = "Mattermost team chat"; };
      affine           = { ip = "10.0.0.6"; desc = "AFFiNE collaborative docs"; };
      photoprism       = { ip = "10.0.0.6"; desc = "PhotoPrism photos"; };
      code-server      = { ip = "10.0.0.6"; desc = "Code Server IDE"; };
      nocodb           = { ip = "10.0.0.6"; desc = "NocoDB database"; };
      windmill-app     = { ip = "10.0.0.6"; desc = "Windmill workflows (oci-apps)"; };
      etherpad         = { ip = "10.0.0.6"; desc = "Etherpad"; };
      filebrowser      = { ip = "10.0.0.6"; desc = "File Browser"; };
      hedgedoc         = { ip = "10.0.0.6"; desc = "HedgeDoc markdown"; };
      revealmd         = { ip = "10.0.0.6"; desc = "Reveal.js MD presentations"; };
      grafana          = { ip = "10.0.0.6"; desc = "Grafana dashboards"; };
      gitea            = { ip = "10.0.0.6"; desc = "Gitea git hosting"; };
      grist            = { ip = "10.0.0.6"; desc = "Grist spreadsheets"; };

      # ── oci-mail (10.0.0.3) ──
      mailu            = { ip = "10.0.0.3"; desc = "Mailu mail server"; };
      syncthing        = { ip = "10.0.0.3"; desc = "Syncthing file sync"; };
      dagu             = { ip = "10.0.0.3"; desc = "Dagu workflow scheduler"; };

      # ── oci-analytics (10.0.0.4) ──
      matomo           = { ip = "10.0.0.4"; desc = "Matomo analytics"; };
      umami            = { ip = "10.0.0.4"; desc = "Umami analytics"; };
      dozzle           = { ip = "10.0.0.4"; desc = "Dozzle container logs"; };
    };

    # VM reverse map for PTR records
    vms = {
      "1" = "gcp-proxy";
      "3" = "oci-mail";
      "4" = "oci-analytics";
      "6" = "oci-apps";
    };

    # ── Per-service zone files ─────────────────────────────────────────
    # Each service gets its own zone: authelia.app, vaultwarden.app, etc.
    # Unknown .app names (google.app) have no zone → root forwarder → Cloudflare.
    mkServiceZone = pkgs: name: ip:
      pkgs.writeText "${name}.${suffix}.zone" ''
$ORIGIN ${name}.${suffix}.
$TTL 60
@  IN SOA  hickory-dns.${suffix}. admin.${suffix}. 1 3600 900 604800 60
@  IN NS   hickory-dns.${suffix}.
@  IN A    ${ip}
'';

    # ── Hickory DNS named.toml ─────────────────────────────────────────
    # Per-service zones + root forwarder for everything else.
    mkNamedToml = pkgs:
      let
        names = builtins.attrNames services;
        zoneBlocks = builtins.concatStringsSep "\n" (
          map (name: ''
      [[zones]]
      zone = "${name}.${suffix}"
      zone_type = "Primary"

      [zones.stores]
      type = "file"
      zone_file_path = "/etc/zones/${name}.${suffix}.zone"
'') names);
      in pkgs.writeText "named.toml" ''
      listen_addrs_ipv4 = ["0.0.0.0"]
      listen_port = 53

      # ── Per-service zones (<name>.app → WG IP) ──
${zoneBlocks}
      # ── Fallback forwarder (everything else → Cloudflare/Google) ──
      [[zones]]
      zone = "."
      zone_type = "External"

      [zones.stores]
      type = "forward"
      name_servers = [
          { socket_addr = "1.1.1.1:53", protocol = "tcp" },
          { socket_addr = "1.1.1.1:53", protocol = "udp" },
          { socket_addr = "1.0.0.1:53", protocol = "tcp" },
          { socket_addr = "1.0.0.1:53", protocol = "udp" },
          { socket_addr = "8.8.8.8:53", protocol = "tcp" },
          { socket_addr = "8.8.8.8:53", protocol = "udp" },
          { socket_addr = "8.8.4.4:53", protocol = "tcp" },
          { socket_addr = "8.8.4.4:53", protocol = "udp" }
      ]
    '';

    # ── Docker Compose ─────────────────────────────────────────────────
    mkDockerCompose = pkgs: docker.mkCompose pkgs {
      banner = docker.banner "~/git/cloud/a_solutions/ba-clo_hickory-dns/src/flake.nix";
      services = {
        hickory-dns = docker.mkService {
          name = "hickory-dns";
          image = "hickorydns/hickory-dns:latest";
          container_name = "hickory-dns";
          ports = [
            "10.0.0.1:53:53/tcp"
            "10.0.0.1:53:53/udp"
          ];
          volumes = [
            "./config/named.toml:/etc/named.toml:ro"
            "./config/zones:/etc/zones:ro"
          ];
          dns = ["1.1.1.1" "8.8.8.8"];
          memLimit = "64M";
        };
      };
    };

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in let
      names = builtins.attrNames services;
      zoneFiles = map (name:
        "cp ${mkServiceZone pkgs name services.${name}.ip} $out/config/zones/${name}.${suffix}.zone"
      ) names;
      defaultPkg = pkgs.runCommand "hickory-dns-configs" {} ''
        mkdir -p $out/config/zones
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${mkNamedToml pkgs} $out/config/named.toml
        ${builtins.concatStringsSep "\n" zoneFiles}
      '';
    in {
      default = defaultPkg;
      docs = docker.mkDocs pkgs { inherit title config defaultPkg; };
    });
  };
}
