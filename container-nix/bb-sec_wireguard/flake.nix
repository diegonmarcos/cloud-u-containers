{
  description = "WireGuard VPN - Docker Compose configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};

    config = {
      container_name = "wireguard";
      image = "linuxserver/wireguard:latest";
      port = 51820;
      timezone = "Europe/Madrid";

      # Server settings
      server_url = "vpn.diegonmarcos.com";
      server_port = "51820";
      internal_subnet = "10.0.0.0/24";

      # Peers (VMs)
      peers = "gcp,oci-micro1,oci-micro2,oci-flex1,surface";
    };

    dockerCompose = pkgs.writeText "docker-compose.yml" ''
      version: "3.8"

      services:
        wireguard:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: unless-stopped
          cap_add:
            - NET_ADMIN
            - SYS_MODULE
          environment:
            TZ: ${config.timezone}
            PUID: 1000
            PGID: 1000
            SERVERURL: ${config.server_url}
            SERVERPORT: ${config.server_port}
            PEERS: ${config.peers}
            PEERDNS: auto
            INTERNAL_SUBNET: ${config.internal_subnet}
            ALLOWEDIPS: 0.0.0.0/0
          ports:
            - "${toString config.port}:51820/udp"
          volumes:
            - ./config:/config
            - /lib/modules:/lib/modules:ro
          sysctls:
            - net.ipv4.conf.all.src_valid_mark=1
          networks:
            - vpn

      networks:
        vpn:
          driver: bridge
    '';

    # Manual WireGuard config template (for non-Docker hosts)
    wgServerConf = pkgs.writeText "wg0.conf" ''
      [Interface]
      Address = 10.0.0.1/24
      ListenPort = 51820
      PrivateKey = CHANGE_ME_SERVER_PRIVATE_KEY

      # GCloud (Central Proxy)
      [Peer]
      PublicKey = CHANGE_ME_GCP_PUBLIC_KEY
      AllowedIPs = 10.0.0.1/32

      # Oracle Micro 1 (Mail)
      [Peer]
      PublicKey = CHANGE_ME_OCI_MICRO1_PUBLIC_KEY
      AllowedIPs = 10.0.0.3/32

      # Oracle Micro 2 (Matomo)
      [Peer]
      PublicKey = CHANGE_ME_OCI_MICRO2_PUBLIC_KEY
      AllowedIPs = 10.0.0.4/32

      # Oracle Flex 1 (Photoprism)
      [Peer]
      PublicKey = CHANGE_ME_OCI_FLEX1_PUBLIC_KEY
      AllowedIPs = 10.0.0.2/32

      # Surface (Local)
      [Peer]
      PublicKey = CHANGE_ME_SURFACE_PUBLIC_KEY
      AllowedIPs = 10.0.0.10/32
    '';

  in {
    packages.${system} = {
      default = pkgs.runCommand "wireguard-configs" {} ''
        mkdir -p $out/config
        cp ${dockerCompose} $out/docker-compose.yml
        cp ${wgServerConf} $out/config/wg0.conf.template
      '';
      docker-compose = dockerCompose;
      wg-config = wgServerConf;
    };

    devShells.${system}.default = pkgs.mkShell {
      packages = [ pkgs.docker-compose pkgs.wireguard-tools ];
    };
  };
}
