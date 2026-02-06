{
  description = "SMTP Proxy/Relay - Docker Compose configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};

    config = {
      container_name = "smtp-proxy";
      image = "namshi/smtp:latest";
      port = 25;
      timezone = "Europe/Madrid";
    };

    dockerCompose = pkgs.writeText "docker-compose.yml" ''
      services:
        smtp-proxy:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: unless-stopped
          env_file:
            - .env
          environment:
            TZ: ${config.timezone}
          ports:
            - "${toString config.port}:25"
          volumes:
            - ./config:/etc/smtp
          networks:
            - proxy

      networks:
        proxy:
          external: true
    '';

  in {
    packages.${system} = {
      default = pkgs.runCommand "smtp-proxy-configs" {} ''
        mkdir -p $out/config
        cp ${dockerCompose} $out/docker-compose.yml
      '';
      docker-compose = dockerCompose;
    };

    devShells.${system}.default = pkgs.mkShell {
      packages = [ pkgs.docker-compose pkgs.sops pkgs.age ];
    };
  };
}
