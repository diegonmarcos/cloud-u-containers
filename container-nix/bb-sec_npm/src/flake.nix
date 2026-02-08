{
  description = "Nginx Proxy Manager - Docker Compose configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      container_name = "npm";
      image = "jc21/nginx-proxy-manager:latest";
      http_port = 80;
      https_port = 443;
      admin_port = 81;
      timezone = "Europe/Madrid";
    };

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      

      services:
        npm:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: unless-stopped
          environment:
            TZ: ${config.timezone}
          ports:
            - "${toString config.http_port}:80"
            - "${toString config.https_port}:443"
            - "${toString config.admin_port}:81"
          volumes:
            - ./data:/data
            - ./letsencrypt:/etc/letsencrypt
          networks:
            - proxy

      networks:
        proxy:
          name: proxy
          driver: bridge
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "npm-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
      '';
    });
  };
}
