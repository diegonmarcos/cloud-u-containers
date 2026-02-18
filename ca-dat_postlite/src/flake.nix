{
  description = "PostLite - SQLite REST API + PostgreSQL wire protocol";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      # SQLite REST API servers (ws4sqlite + postlite)
      # Deployed on: gcp-E2-f_0 (35.226.147.64)
      # Access via WireGuard only (10.0.0.1:8880-8883, 5433-5436)

      services:
        sqlite-npm:
          image: germanorizzo/ws4sqlite:latest
          container_name: sqlite-npm
          restart: unless-stopped
          ports:
            - "10.0.0.1:8880:12321"
          volumes:
            - /home/diego/npm/data:/data
          command: ["-db", "/data/database.sqlite?mode=ro"]

        sqlite-vaultwarden:
          image: germanorizzo/ws4sqlite:latest
          container_name: sqlite-vaultwarden
          restart: unless-stopped
          ports:
            - "10.0.0.1:8881:12321"
          volumes:
            - /home/diego/vaultwarden/data:/data
          command: ["-db", "/data/db.sqlite3?mode=ro"]

        sqlite-ntfy:
          image: germanorizzo/ws4sqlite:latest
          container_name: sqlite-ntfy
          restart: unless-stopped
          ports:
            - "10.0.0.1:8882:12321"
          volumes:
            - /home/diego/ntfy/cache:/data
          command: ["-db", "/data/cache.db?mode=ro"]

        sqlite-authelia:
          image: germanorizzo/ws4sqlite:latest
          container_name: sqlite-authelia
          restart: unless-stopped
          ports:
            - "10.0.0.1:8883:12321"
          volumes:
            - /home/diego/authelia/config:/data
          command: ["-db", "/data/db.sqlite3?mode=ro"]

        postlite-npm:
          build:
            context: .
            dockerfile: Dockerfile
          image: postlite:latest
          container_name: postlite-npm
          restart: unless-stopped
          ports:
            - "10.0.0.1:5433:5432"
          volumes:
            - /home/diego/npm/data:/data
          command: ["-addr", ":5432", "-data-dir", "/data"]

        postlite-vaultwarden:
          image: postlite:latest
          container_name: postlite-vaultwarden
          restart: unless-stopped
          ports:
            - "10.0.0.1:5434:5432"
          volumes:
            - /home/diego/vaultwarden/data:/data
          command: ["-addr", ":5432", "-data-dir", "/data"]

        postlite-ntfy:
          image: postlite:latest
          container_name: postlite-ntfy
          restart: unless-stopped
          ports:
            - "10.0.0.1:5435:5432"
          volumes:
            - /home/diego/ntfy/cache:/data
          command: ["-addr", ":5432", "-data-dir", "/data"]

        postlite-authelia:
          image: postlite:latest
          container_name: postlite-authelia
          restart: unless-stopped
          ports:
            - "10.0.0.1:5436:5432"
          volumes:
            - /home/diego/authelia/config:/data
          command: ["-addr", ":5432", "-data-dir", "/data"]
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "postlite-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${./Dockerfile} $out/Dockerfile
      '';
    });
  };
}
