{
  description = "Vaultwarden (Bitwarden-compatible) Password Manager - Docker Compose configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};

    config = {
      domain = "vault.diegonmarcos.com";
      container_name = "vaultwarden";
      image = "vaultwarden/server:latest";
      port = 8080;
      timezone = "Europe/Madrid";

      # Security settings
      admin_token = "CHANGE_ME_ADMIN_TOKEN";  # Generate with: openssl rand -base64 48
      signups_allowed = "false";
      invitations_allowed = "true";
      show_password_hint = "false";

      # SMTP for notifications (optional)
      smtp_host = "";
      smtp_from = "vault@diegonmarcos.com";
    };

    dockerCompose = pkgs.writeText "docker-compose.yml" ''
      version: "3.8"

      services:
        vaultwarden:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: unless-stopped
          environment:
            TZ: ${config.timezone}
            DOMAIN: https://${config.domain}
            ADMIN_TOKEN: ${config.admin_token}
            SIGNUPS_ALLOWED: ${config.signups_allowed}
            INVITATIONS_ALLOWED: ${config.invitations_allowed}
            SHOW_PASSWORD_HINT: ${config.show_password_hint}
            WEBSOCKET_ENABLED: "true"
            LOG_LEVEL: info
          ports:
            - "${toString config.port}:80"
            - "3012:3012"  # WebSocket
          volumes:
            - ./data:/data
          networks:
            - proxy

      networks:
        proxy:
          external: true
    '';

  in {
    packages.${system} = {
      default = pkgs.runCommand "vaultwarden-configs" {} ''
        mkdir -p $out/data
        cp ${dockerCompose} $out/docker-compose.yml
      '';
      docker-compose = dockerCompose;
    };

    devShells.${system}.default = pkgs.mkShell {
      packages = [ pkgs.docker-compose pkgs.openssl ];
    };
  };
}
