{
  description = "Code Server (VS Code in browser) - Docker Compose configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};

    config = {
      domain = "ide.diegonmarcos.com";
      container_name = "code-server";
      image = "linuxserver/code-server:latest";
      port = 8443;
      timezone = "Europe/Madrid";

      # Auth
      password = "CHANGE_ME_PASSWORD";
      sudo_password = "CHANGE_ME_SUDO_PASSWORD";
    };

    dockerCompose = pkgs.writeText "docker-compose.yml" ''
      version: "3.8"

      services:
        code-server:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: unless-stopped
          environment:
            TZ: ${config.timezone}
            PUID: 1000
            PGID: 1000
            PASSWORD: ${config.password}
            SUDO_PASSWORD: ${config.sudo_password}
            PROXY_DOMAIN: ${config.domain}
          ports:
            - "${toString config.port}:8443"
          volumes:
            - ./config:/config
            - ./workspace:/workspace
          networks:
            - proxy

      networks:
        proxy:
          external: true
    '';

  in {
    packages.${system} = {
      default = pkgs.runCommand "code-server-configs" {} ''
        mkdir -p $out/{config,workspace}
        cp ${dockerCompose} $out/docker-compose.yml
      '';
      docker-compose = dockerCompose;
    };

    devShells.${system}.default = pkgs.mkShell {
      packages = [ pkgs.docker-compose ];
    };
  };
}
