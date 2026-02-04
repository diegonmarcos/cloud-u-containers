{
  description = "GitHub RSS - RSS Feed Generator for GitHub Activity";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};

    config = {
      container_name = "github-rss";
      image = "rsshub/rsshub:latest";
      port = 1200;
      timezone = "Europe/Madrid";

      # GitHub token for API access
      github_token = "CHANGE_ME_GITHUB_TOKEN";
    };

    dockerCompose = pkgs.writeText "docker-compose.yml" ''
      version: "3.8"

      services:
        github-rss:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: unless-stopped
          environment:
            TZ: ${config.timezone}
            GITHUB_ACCESS_TOKEN: ${config.github_token}
            CACHE_TYPE: memory
            CACHE_EXPIRE: 300
            REQUEST_TIMEOUT: 5000
          ports:
            - "${toString config.port}:1200"
          volumes:
            - ./data:/app/data
          networks:
            - proxy
          healthcheck:
            test: ["CMD", "wget", "-q", "--spider", "http://localhost:1200/"]
            interval: 30s
            timeout: 10s
            retries: 3

      networks:
        proxy:
          external: true
    '';

  in {
    packages.${system} = {
      default = pkgs.runCommand "github-rss-configs" {} ''
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
