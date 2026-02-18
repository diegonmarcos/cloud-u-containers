{
  description = "SMTP Proxy/Relay - Docker Compose configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      container_name = "smtp-proxy";
      port = 8080;
    };

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      services:
        smtp-proxy:
          build: .
          container_name: ${config.container_name}
          restart: unless-stopped
          ports:
            - "${toString config.port}:8080"
          environment:
            - SMTP_HOST=front
            - SMTP_PORT=25
            - API_KEY=stalwart-proxy-key-2025
            - LISTEN_PORT=8080
          networks:
            - mailu_default

      networks:
        mailu_default:
          external: true
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "smtp-proxy-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${./Dockerfile} $out/Dockerfile
        cp ${./nginx.conf} $out/nginx.conf
        cp ${./smtp_proxy.py} $out/smtp_proxy.py
      '';
    });
  };
}
