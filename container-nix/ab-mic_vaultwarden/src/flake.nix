{
  description = "Vaultwarden (Bitwarden-compatible) Password Manager - Docker Compose configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      domain = "vault.diegonmarcos.com";
      container_name = "vaultwarden";
      image = "vaultwarden/server:latest";
      port = 8080;
      timezone = "Europe/Madrid";

      # Non-secret settings
      signups_allowed = "false";
      invitations_allowed = "true";
      show_password_hint = "false";
    };

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      services:
        vaultwarden:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: unless-stopped
          env_file:
            - .env
          environment:
            TZ: ${config.timezone}
            DOMAIN: https://${config.domain}
            SIGNUPS_ALLOWED: ${config.signups_allowed}
            INVITATIONS_ALLOWED: ${config.invitations_allowed}
            SHOW_PASSWORD_HINT: ${config.show_password_hint}
            WEBSOCKET_ENABLED: "true"
            LOG_LEVEL: info
          ports:
            - "${toString config.port}:80"
            - "3012:3012"
          volumes:
            - ./data:/data
          networks:
            - proxy

      networks:
        proxy:
          external: true
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "vaultwarden-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
      '';
    });
  };
}
