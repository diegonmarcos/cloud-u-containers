{
  description = "Hickory DNS - Internal DNS server for WireGuard mesh (.internal zone)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {};

    title = "Hickory DNS";
    docker = import ../../_shared/docker.nix;

    # ── Service registry (single source of truth) ──────────────────────
    services = {
      # gcp-proxy (10.0.0.1)
      caddy    = { ip = "10.0.0.1"; desc = "Reverse proxy"; };
      auth     = { ip = "10.0.0.1"; desc = "Authelia 2FA"; };
      vault    = { ip = "10.0.0.1"; desc = "Vaultwarden"; };
      api      = { ip = "10.0.0.1"; desc = "API gateway"; };
      ntfy     = { ip = "10.0.0.1"; desc = "Push notifications"; };
      dns      = { ip = "10.0.0.1"; desc = "Hickory DNS"; };

      # oci-apps (10.0.0.6)
      photos   = { ip = "10.0.0.6"; desc = "PhotoPrism"; };
      db       = { ip = "10.0.0.6"; desc = "NocoDB"; };
      ide      = { ip = "10.0.0.6"; desc = "Code Server"; };
      affine   = { ip = "10.0.0.6"; desc = "AFFiNE"; };

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
      "3" = "oci-mail";
      "4" = "oci-analytics";
      "6" = "oci-apps";
    };

    # ── Hickory DNS named.toml ─────────────────────────────────────────
    # Pure forwarder — NO local zones. ALL queries go to Cloudflare/Google.
    mkNamedToml = pkgs: pkgs.writeText "named.toml" ''
      listen_addrs_ipv4 = ["0.0.0.0"]
      listen_port = 53

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
          volumes = ["./config/named.toml:/etc/named.toml:ro"];
          dns = ["1.1.1.1" "8.8.8.8"];
          memLimit = "64M";
        };
      };
    };

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in let
      defaultPkg = pkgs.runCommand "hickory-dns-configs" {} ''
        mkdir -p $out/config
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${mkNamedToml pkgs} $out/config/named.toml
      '';
    in {
      default = defaultPkg;
      docs = docker.mkDocs pkgs { inherit title config defaultPkg; };
    });
  };
}
