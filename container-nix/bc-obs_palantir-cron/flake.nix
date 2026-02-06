{
  description = "Palantir Cron - Scheduled Task Runner";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};

    config = {
      container_name = "palantir-cron";
      image = "mcuadros/ofelia:latest";  # Cron job scheduler for Docker
      timezone = "Europe/Madrid";
    };

    dockerCompose = pkgs.writeText "docker-compose.yml" ''
      

      services:
        palantir-cron:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: unless-stopped
          environment:
            TZ: ${config.timezone}
          volumes:
            - /var/run/docker.sock:/var/run/docker.sock:ro
            - ./config/config.ini:/etc/ofelia/config.ini:ro
          networks:
            - proxy
          labels:
            ofelia.enabled: "true"

      networks:
        proxy:
          external: true
    '';

    # Ofelia cron configuration
    cronConfig = pkgs.writeText "config.ini" ''
      [global]
      save-folder = /var/log/ofelia

      # Example: Clean up old Docker images weekly
      [job-exec "docker-cleanup"]
      schedule = @weekly
      container = palantir-cron
      command = docker system prune -af --volumes

      # Example: Health check ping every 5 minutes
      [job-exec "healthcheck"]
      schedule = @every 5m
      container = palantir-cron
      command = wget -q --spider http://ntfy:80/health || true

      # Add more scheduled jobs as needed
    '';

  in {
    packages.${system} = {
      default = pkgs.runCommand "palantir-cron-configs" {} ''
        mkdir -p $out/config
        cp ${dockerCompose} $out/docker-compose.yml
        cp ${cronConfig} $out/config/config.ini
      '';
      docker-compose = dockerCompose;
    };

    devShells.${system}.default = pkgs.mkShell {
      packages = [ pkgs.docker-compose pkgs.sops pkgs.age ];
    };
  };
}
