{
  description = "ntfy Push Notifications - Docker Compose configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};

    config = {
      domain = "rss.diegonmarcos.com";
      container_name = "ntfy";
      image = "binwiederhier/ntfy:latest";
      port = 8080;
      timezone = "Europe/Madrid";
    };

    dockerCompose = pkgs.writeText "docker-compose.yml" ''
      

      services:
        ntfy:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: unless-stopped
          command: serve
          environment:
            TZ: ${config.timezone}
            NTFY_BASE_URL: https://${config.domain}
            NTFY_UPSTREAM_BASE_URL: https://ntfy.sh
            NTFY_CACHE_FILE: /var/cache/ntfy/cache.db
            NTFY_AUTH_FILE: /var/lib/ntfy/auth.db
            NTFY_AUTH_DEFAULT_ACCESS: deny-all
            NTFY_BEHIND_PROXY: "true"
            NTFY_ENABLE_LOGIN: "true"
          ports:
            - "${toString config.port}:80"
          volumes:
            - ./cache:/var/cache/ntfy
            - ./data:/var/lib/ntfy
          networks:
            - proxy

      networks:
        proxy:
          external: true
    '';

  in {
    packages.${system} = {
      default = pkgs.runCommand "ntfy-configs" {} ''
        mkdir -p $out/{cache,data}
        cp ${dockerCompose} $out/docker-compose.yml
      '';
      docker-compose = dockerCompose;
    };

    devShells.${system}.default = pkgs.mkShell {
      packages = [ pkgs.docker-compose pkgs.ntfy-sh pkgs.sops pkgs.age ];
    };
  };
}
