{
  description = "Vaultwarden (Bitwarden-compatible) Password Manager - Docker Compose configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    docker = import ../../_shared/docker.nix;
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    svc = (builtins.fromJSON (builtins.readFile ../../../cloud-data/cloud-data-service-connections.json)).services;

    config = {
      domain = buildJson.domain;
      container_name = "vaultwarden";
      image = "vaultwarden/server:latest";
      port = buildJson.ports.app;
      timezone = "Europe/Madrid";

      signups_allowed = "true";
      invitations_allowed = "true";
      show_password_hint = "false";
    };

    title = "Vaultwarden (Bitwarden-compatible) Password Manager";

    mkDockerCompose = pkgs: docker.mkCompose pkgs {
      banner = docker.banner "~/git/cloud/a_solutions/ab-mic_vaultwarden/src/flake.nix";

      services.vaultwarden = docker.mkService {
        name = "vaultwarden";
        image = config.image;
        container_name = config.container_name;
        networkMode = "host";

        env_file = [ ".secrets" ];
        environment = {
          DOMAIN = "https://${config.domain}";
          ROCKET_PORT = "\"${toString config.port}\"";
          SIGNUPS_ALLOWED = config.signups_allowed;
          INVITATIONS_ALLOWED = config.invitations_allowed;
          SHOW_PASSWORD_HINT = config.show_password_hint;
          WEBSOCKET_ENABLED = "\"true\"";
          LOG_LEVEL = "warn";
          SMTP_HOST = svc.stalwart.ip;
          SMTP_FROM = "noreply@diegonmarcos.com";
          SMTP_PORT = "\"${toString svc.stalwart.ports.smtp}\"";
          SMTP_SECURITY = "force_tls";
          SMTP_USERNAME = "noreply@diegonmarcos.com";
          SMTP_PASSWORD = "\${SMTP_PASSWORD}";
          ADMIN_TOKEN = "\${ADMIN_TOKEN}";
        };
        volumes = [ "vaultwarden_data:/data" ];
      };

      volumes = {
        vaultwarden_data = {};
      };
    };

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in let
      defaultPkg = pkgs.runCommand "vaultwarden-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
      '';
    in {
      default = defaultPkg;
      docs = docker.mkDocs pkgs { inherit title config defaultPkg; };
    });
  };
}
