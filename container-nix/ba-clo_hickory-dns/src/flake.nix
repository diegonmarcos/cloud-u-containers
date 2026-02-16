{
  description = "Hickory DNS - Internal DNS server for WireGuard mesh (.internal zone)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # ── Service registry (single source of truth) ──────────────────────
    services = {
      # gcp-proxy (10.0.0.1)
      caddy    = { ip = "10.0.0.1"; desc = "Reverse proxy"; };
      auth     = { ip = "10.0.0.1"; desc = "Authelia 2FA"; };
      vault    = { ip = "10.0.0.1"; desc = "Vaultwarden"; };
      api      = { ip = "10.0.0.1"; desc = "API gateway"; };
      ntfy     = { ip = "10.0.0.1"; desc = "Push notifications"; };
      dns      = { ip = "10.0.0.1"; desc = "Hickory DNS"; };

      # oci-apps-1 (10.0.0.2)
      photos   = { ip = "10.0.0.2"; desc = "PhotoPrism"; };
      db       = { ip = "10.0.0.2"; desc = "NocoDB"; };
      ide      = { ip = "10.0.0.2"; desc = "Code Server"; };
      affine   = { ip = "10.0.0.2"; desc = "AFFiNE"; };

      # oci-mail (10.0.0.3)
      mail     = { ip = "10.0.0.3"; desc = "Mailu"; };
      sync     = { ip = "10.0.0.3"; desc = "Syncthing"; };
      cal      = { ip = "10.0.0.3"; desc = "Radicale"; };

      # oci-analytics (10.0.0.4)
      matomo   = { ip = "10.0.0.4"; desc = "Matomo analytics"; };
      windmill = { ip = "10.0.0.4"; desc = "Windmill workflows"; };
    };

    # VM reverse map for PTR records
    vms = {
      "1" = "gcp-proxy";
      "2" = "oci-apps-1";
      "3" = "oci-mail";
      "4" = "oci-analytics";
      "6" = "oci-flex-0";
    };

    # ── Zone file generators ───────────────────────────────────────────
    mkForwardZone = pkgs: let
      records = builtins.concatStringsSep "\n" (
        nixpkgs.lib.mapAttrsToList (name: svc:
          "${name}          IN  A     ${svc.ip}    ; ${svc.desc}"
        ) services
      );
    in pkgs.writeText "internal.zone" ''
      $TTL 3600
      @   IN  SOA   dns.internal. admin.internal. (
                    2026021601  ; serial (YYYYMMDDNN)
                    3600        ; refresh
                    900         ; retry
                    604800      ; expire
                    300 )       ; negative cache TTL

          IN  NS    dns.internal.

      ; ── Service A records ──
      ${records}

      ; ── Wildcard (unmatched → Caddy) ──
      *            IN  A     10.0.0.1
    '';

    mkReverseZone = pkgs: let
      ptrRecords = builtins.concatStringsSep "\n" (
        nixpkgs.lib.mapAttrsToList (octet: hostname:
          "${octet}    IN  PTR   ${hostname}.internal."
        ) vms
      );
    in pkgs.writeText "0.0.10.in-addr.arpa.zone" ''
      $TTL 3600
      @   IN  SOA   dns.internal. admin.internal. (
                    2026021601  ; serial
                    3600        ; refresh
                    900         ; retry
                    604800      ; expire
                    300 )       ; negative cache TTL

          IN  NS    dns.internal.

      ; ── PTR records ──
      ${ptrRecords}
    '';

    # ── Hickory DNS named.toml ─────────────────────────────────────────
    mkNamedToml = pkgs: pkgs.writeText "named.toml" ''
      listen_addrs_ipv4 = ["0.0.0.0"]
      listen_port = 53
      directory = "/var/named"

      [[zones]]
      zone = "internal"
      zone_type = "Primary"
      file = "internal.zone"

      [[zones]]
      zone = "0.0.10.in-addr.arpa"
      zone_type = "Primary"
      file = "0.0.10.in-addr.arpa.zone"

      [[zones]]
      zone = "."
      zone_type = "External"

      [zones.stores]
      type = "forward"
      name_servers = [
          { socket_addr = "1.1.1.1:53", protocol = "udp" },
          { socket_addr = "1.0.0.1:53", protocol = "udp" },
          { socket_addr = "8.8.8.8:53", protocol = "udp" },
          { socket_addr = "8.8.4.4:53", protocol = "udp" }
      ]
    '';

    # ── Docker Compose ─────────────────────────────────────────────────
    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      services:
        hickory-dns:
          image: hickorydns/hickory-dns:latest
          container_name: hickory-dns
          restart: unless-stopped
          ports:
            - "10.0.0.1:53:53/tcp"
            - "10.0.0.1:53:53/udp"
          volumes:
            - ./config/named.toml:/etc/named.toml:ro
            - ./zones:/var/named:ro
          dns:
            - 1.1.1.1
            - 8.8.8.8
          deploy:
            resources:
              limits:
                memory: 64M
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "hickory-dns-configs" {} ''
        mkdir -p $out/config $out/zones
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${mkNamedToml pkgs} $out/config/named.toml
        cp ${mkForwardZone pkgs} $out/zones/internal.zone
        cp ${mkReverseZone pkgs} $out/zones/0.0.10.in-addr.arpa.zone
      '';
    });
  };
}
