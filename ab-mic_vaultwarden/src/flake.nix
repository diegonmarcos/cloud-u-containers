{
  description = "Vaultwarden (Bitwarden-compatible) Password Manager - Docker Compose configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    docker = import ../../_shared/docker.nix;
    ports = import ../../_shared/lib/port-enforcement.nix { buildJsonPath = ../build.json; };

    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    # Single source of truth: build-vaultwarden.json (symlink → I_cloud-data/
    # build-vaultwarden.json). Engine resolves symlink before nix build.
    buildVaultwarden = builtins.fromJSON (builtins.readFile ./build-vaultwarden.json);
    svc = buildVaultwarden.services;

    lib = nixpkgs.lib;

    # base_domain derived from service domain: "vault.example.com" → "example.com"
    base_domain =
      let parts = lib.splitString "." buildJson.domain;
      in lib.concatStringsSep "." (lib.drop 1 parts);

    # GHCR image: wraps public image with OCI label for GHCR
    ghcr = docker.mkGhcrBuild {
      name = "vaultwarden";
      fromImage = buildJson.upstream_image;
    };

    config = {
      domain = buildJson.domain;
      base_domain = base_domain;
      container_name = buildVaultwarden.container.container_name;
      image = ghcr.image;
      port = buildJson.ports.app;
      timezone = buildJson.timezone;

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
        build = ghcr.build;
        container_name = config.container_name;
        networkMode = "host";
        portEnv = ports.envFor "app";

        env_file = [ ".secrets" ];
        environment = {
          ROCKET_ADDRESS = svc.vaultwarden.ip;  # bind to WG IP only
          TZ = config.timezone;
          DOMAIN = "https://${config.domain}";
          SIGNUPS_ALLOWED = config.signups_allowed;
          INVITATIONS_ALLOWED = config.invitations_allowed;
          SHOW_PASSWORD_HINT = config.show_password_hint;
          WEBSOCKET_ENABLED = "\"true\"";
          LOG_LEVEL = "warn";
          SMTP_HOST = svc.maddy.ip;
          SMTP_FROM = "noreply@${config.base_domain}";
          SMTP_PORT = "\"${toString svc.maddy.ports.smtp}\"";
          SMTP_SECURITY = "force_tls";
          SMTP_USERNAME = "noreply@${config.base_domain}";
          SMTP_PASSWORD = "\${SMTP_PASSWORD}";
          ADMIN_TOKEN = "\${ADMIN_TOKEN}";
        };
        volumes = [ "vaultwarden_data:/data" ];
        memLimit = buildJson.resources.mem_limit;
        memReservation = buildJson.resources.mem_reservation;
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
