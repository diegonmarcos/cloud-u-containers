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
      timezone = "Europe/Madrid";

      signups_allowed = "true";
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
            - .secrets
          environment:
            DOMAIN: https://${config.domain}
            SIGNUPS_ALLOWED: ${config.signups_allowed}
            INVITATIONS_ALLOWED: ${config.invitations_allowed}
            SHOW_PASSWORD_HINT: ${config.show_password_hint}
            WEBSOCKET_ENABLED: "true"
            LOG_LEVEL: warn
            SMTP_HOST: smtp.diegonmarcos.com
            SMTP_FROM: noreply@diegonmarcos.com
            SMTP_PORT: "465"
            SMTP_SECURITY: force_tls
            SMTP_USERNAME: noreply@diegonmarcos.com
            SMTP_PASSWORD: ''${SMTP_PASSWORD}
            ADMIN_TOKEN: ''${ADMIN_TOKEN}
          volumes:
            - ./data:/data
          networks:
            - npm_default

      networks:
        npm_default:
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
