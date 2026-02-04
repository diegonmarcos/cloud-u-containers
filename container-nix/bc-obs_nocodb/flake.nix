{
  description = "NocoDB Database UI - Docker Compose configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};

    config = {
      domain = "db.diegonmarcos.com";
      container_name = "nocodb";
      image = "nocodb/nocodb:latest";
      port = 8080;
      timezone = "Europe/Madrid";

      # Auth
      nc_auth_jwt_secret = "CHANGE_ME_JWT_SECRET";
    };

    dockerCompose = pkgs.writeText "docker-compose.yml" ''
      version: "3.8"

      services:
        nocodb:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: unless-stopped
          environment:
            TZ: ${config.timezone}
            NC_AUTH_JWT_SECRET: ${config.nc_auth_jwt_secret}
            NC_PUBLIC_URL: https://${config.domain}
          ports:
            - "${toString config.port}:8080"
          volumes:
            - ./data:/usr/app/data
          networks:
            - proxy

      networks:
        proxy:
          external: true
    '';

  in {
    packages.${system} = {
      default = pkgs.runCommand "nocodb-configs" {} ''
        mkdir -p $out/data
        cp ${dockerCompose} $out/docker-compose.yml
      '';
      docker-compose = dockerCompose;
    };

    devShells.${system}.default = pkgs.mkShell {
      packages = [ pkgs.docker-compose ];
    };
  };
}
