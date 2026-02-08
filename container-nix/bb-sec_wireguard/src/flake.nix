{
  description = "WireGuard VPN - Native deployment (NOT Docker)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # WireGuard runs NATIVELY on all VMs, not in Docker containers
    # This flake only generates wg0.conf templates for b_infra/vm_*/1.os/
    mkReadme = pkgs: pkgs.writeText "README.md" ''
      # WireGuard - Native Deployment

      WireGuard runs NATIVELY on all VMs, not in Docker containers.
      See b_infra/vm_*/1.os/wireguard-wg0.conf for actual configs.

      ## Mesh Topology

          GCP Hub (10.0.0.1) - 35.226.147.64:51820
              |
              +-- Oracle Flex  (10.0.0.2) - 144.24.196.72:51820
              +-- Oracle Micro1 (10.0.0.3) - 130.110.251.193:51820
              +-- Oracle Micro2 (10.0.0.4) - 129.151.228.66:51820
              +-- Local Machine (10.0.0.5) - dynamic IP

      All peers connect to GCP Hub, which routes traffic between them.
    '';

    # Template wg0.conf for GCP hub
    mkWgHubConf = pkgs: pkgs.writeText "wg0-hub.conf.template" ''
      [Interface]
      Address = 10.0.0.1/24
      ListenPort = 51820
      PrivateKey = <REDACTED>

      # Oracle Flex (10.0.0.2)
      [Peer]
      PublicKey = CHANGE_ME
      AllowedIPs = 10.0.0.2/32
      Endpoint = 144.24.196.72:51820

      # Oracle Micro 1 (10.0.0.3)
      [Peer]
      PublicKey = CHANGE_ME
      AllowedIPs = 10.0.0.3/32
      Endpoint = 130.110.251.193:51820

      # Oracle Micro 2 (10.0.0.4)
      [Peer]
      PublicKey = CHANGE_ME
      AllowedIPs = 10.0.0.4/32
      Endpoint = 129.151.228.66:51820

      # Local Machine (10.0.0.5)
      [Peer]
      PublicKey = CHANGE_ME
      AllowedIPs = 10.0.0.5/32
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "wireguard-configs" {} ''
        mkdir -p $out
        cp ${mkReadme pkgs} $out/README.md
        cp ${mkWgHubConf pkgs} $out/wg0-hub.conf.template
      '';
    });
  };
}
