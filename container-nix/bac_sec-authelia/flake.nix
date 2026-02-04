{
  description = "Authelia 2FA Authentication - Docker Compose configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};

    # Configuration options
    config = {
      domain = "auth.diegonmarcos.com";
      container_name = "authelia";
      image = "authelia/authelia:latest";
      port = 9091;
      timezone = "Europe/Madrid";

      # Secrets (override these in secrets/secrets.nix)
      jwt_secret = "CHANGE_ME_JWT_SECRET";
      session_secret = "CHANGE_ME_SESSION_SECRET";
      storage_encryption_key = "CHANGE_ME_ENCRYPTION_KEY";
    };

    # Generate docker-compose.yml
    dockerCompose = pkgs.writeText "docker-compose.yml" ''
      version: "3.8"

      services:
        authelia:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: unless-stopped
          environment:
            TZ: ${config.timezone}
          volumes:
            - ./config:/config
          ports:
            - "${toString config.port}:9091"
          networks:
            - proxy

      networks:
        proxy:
          external: true
    '';

    # Generate authelia configuration.yml
    autheliaConfig = pkgs.writeText "configuration.yml" ''
      ---
      theme: dark

      server:
        host: 0.0.0.0
        port: 9091

      log:
        level: info

      totp:
        issuer: ${config.domain}
        period: 30
        skew: 1

      authentication_backend:
        file:
          path: /config/users_database.yml
          password:
            algorithm: argon2id
            iterations: 1
            key_length: 32
            salt_length: 16
            memory: 1024
            parallelism: 8

      access_control:
        default_policy: deny
        rules:
          - domain: "*.diegonmarcos.com"
            policy: two_factor

      session:
        name: authelia_session
        domain: diegonmarcos.com
        expiration: 3600
        inactivity: 300
        remember_me_duration: 1M

      regulation:
        max_retries: 3
        find_time: 120
        ban_time: 300

      storage:
        local:
          path: /config/db.sqlite3

      notifier:
        filesystem:
          filename: /config/notification.txt
    '';

    # Generate users database template
    usersDatabase = pkgs.writeText "users_database.yml" ''
      ---
      users:
        diego:
          displayname: "Diego"
          # Generate with: docker run authelia/authelia:latest authelia crypto hash generate argon2 --password 'yourpassword'
          password: "$argon2id$v=19$m=65536,t=3,p=4$CHANGE_ME_HASH"
          email: diego@diegonmarcos.com
          groups:
            - admins
            - users
    '';

    # Build script to assemble everything
    buildScript = pkgs.writeShellScriptBin "build-authelia" ''
      set -e
      OUTDIR="$1"
      if [ -z "$OUTDIR" ]; then
        OUTDIR="./result"
      fi
      mkdir -p "$OUTDIR/config"
      cp ${dockerCompose} "$OUTDIR/docker-compose.yml"
      cp ${autheliaConfig} "$OUTDIR/config/configuration.yml"
      cp ${usersDatabase} "$OUTDIR/config/users_database.yml"
      chmod -R u+w "$OUTDIR"
      echo "Authelia configs built in $OUTDIR"
    '';

  in {
    packages.${system} = {
      default = pkgs.runCommand "authelia-configs" {} ''
        mkdir -p $out/config
        cp ${dockerCompose} $out/docker-compose.yml
        cp ${autheliaConfig} $out/config/configuration.yml
        cp ${usersDatabase} $out/config/users_database.yml
      '';

      docker-compose = dockerCompose;
      config = autheliaConfig;
      build = buildScript;
    };

    # Development shell with useful tools
    devShells.${system}.default = pkgs.mkShell {
      packages = [ pkgs.docker-compose pkgs.yq-go ];
    };
  };
}
