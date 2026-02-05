{
  description = "Nginx Proxy Manager - Docker Compose configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};

    config = {
      container_name = "npm";
      image = "jc21/nginx-proxy-manager:latest";
      http_port = 80;
      https_port = 443;
      admin_port = 81;
      timezone = "Europe/Madrid";
    };

    dockerCompose = pkgs.writeText "docker-compose.yml" ''
      

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
    packages.${system} = {
      default = pkgs.runCommand "npm-configs" {} ''
        mkdir -p $out/{data,letsencrypt}
        cp ${dockerCompose} $out/docker-compose.yml
      '';
      docker-compose = dockerCompose;
    };

    devShells.${system}.default = pkgs.mkShell {
      packages = [ pkgs.docker-compose ];
    };
  };
}
