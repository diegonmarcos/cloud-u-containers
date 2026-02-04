{
  description = "Authelia 2FA Authentication - Docker Compose configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};

    # Configuration options (non-secret)
    config = {
      domain = "auth.diegonmarcos.com";
      container_name = "authelia";
      image = "authelia/authelia:latest";
      port = 9091;
      timezone = "Europe/Madrid";
    };

    # Generate docker-compose.yml
    dockerCompose = pkgs.writeText "docker-compose.yml" ''
      services:
        authelia:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: unless-stopped
          env_file:
            - .env
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

    # Generate authelia configuration.yml (reads secrets from env vars)
    autheliaConfig = pkgs.writeText "configuration.yml" ''
      ---
      theme: dark

      server:
        address: tcp://0.0.0.0:9091/

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
        cookies:
          - domain: diegonmarcos.com
            authelia_url: https://${config.domain}
        expiration: 3600
        inactivity: 300
        remember_me: 1M

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

    # Users database template (hash comes from .env via init script)
    usersDatabase = pkgs.writeText "users_database.yml" ''
      ---
      users:
        diego:
          displayname: "Diego"
          password: "${"\${AUTHELIA_USER_DIEGO_HASH}"}"
          email: diego@diegonmarcos.com
          groups:
            - admins
            - users
    '';

    # Init script to substitute env vars into users_database.yml
    initScript = pkgs.writeText "init.sh" ''
      #!/bin/sh
      # Substitute environment variables into users_database.yml
      envsubst < /config/users_database.yml.tpl > /config/users_database.yml
    '';

  in {
    packages.${system} = {
      default = pkgs.runCommand "authelia-configs" {} ''
        mkdir -p $out/config
        cp ${dockerCompose} $out/docker-compose.yml
        cp ${autheliaConfig} $out/config/configuration.yml
        cp ${usersDatabase} $out/config/users_database.yml.tpl
        cp ${initScript} $out/init.sh
      '';
    };

    devShells.${system}.default = pkgs.mkShell {
      packages = [ pkgs.docker-compose pkgs.sops pkgs.age ];
    };
  };
}
