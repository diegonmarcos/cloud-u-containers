{
  description = "SMTP Proxy/Relay - Docker Compose configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      container_name = "smtp-proxy";
      port = 8025;
    };

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      services:
        smtp-proxy:
          build: .
          container_name: ${config.container_name}
          restart: unless-stopped
          ports:
            - "${toString config.port}:8025"
          environment:
            - SMTP_HOST=stalwart-mail
            - SMTP_PORT=25
            - SMTP_USER=me@diegonmarcos.com
            - SMTP_PASS=''${SMTP_PASS}
            - API_KEY=''${API_KEY}
            - LISTEN_PORT=8025
            - HELO_DOMAIN=smtp-proxy.diegonmarcos.com
          networks:
            - mail_network

      networks:
        mail_network:
          external: true
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "smtp-proxy-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
      '';
    });
  };
}
