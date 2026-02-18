{
  description = "GitHub RSS - RSS Feed Generator for GitHub Activity";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      container_name = "github-rss";
      image = "rsshub/rsshub:latest";
      port = 1200;
      timezone = "Europe/Madrid";

      # GitHub token for API access
      github_token = "CHANGE_ME_GITHUB_TOKEN";
    };

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      

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
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "github-rss-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
      '';
    });
  };
}
