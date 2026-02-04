{
  description = "Cloud Infrastructure - All Docker services managed with Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

    # Application services (app_)
    affine.url = "path:./app_affine";
    code-server.url = "path:./app_code-server";
    github-rss.url = "path:./app_github-rss";
    nocodb.url = "path:./app_nocodb";
    ntfy.url = "path:./app_ntfy";
    photoprism.url = "path:./app_photoprism";
    radicale.url = "path:./app_radicale";
    syncthing.url = "path:./app_syncthing";

    # Backend tools (bac_tools-)
    c3-collector.url = "path:./bac_tools-c3-collector";
    flask-api.url = "path:./bac_tools-flask-api";
    mailu.url = "path:./bac_tools-mailu";
    matomo.url = "path:./bac_tools-matomo";
    npm.url = "path:./bac_tools-npm";
    palantir-cron.url = "path:./bac_tools-palantir-cron";
    redis.url = "path:./bac_tools-redis";
    smtp-proxy.url = "path:./bac_tools-smtp-proxy";
    syslog.url = "path:./bac_tools-syslog";

    # Backend security (bac_sec-)
    authelia.url = "path:./bac_sec-authelia";
    introspect-proxy.url = "path:./bac_sec-introspect-proxy";
    sauron-lite.url = "path:./bac_sec-sauron-lite";
    vaultwarden.url = "path:./bac_sec-vaultwarden";
    wireguard.url = "path:./bac_sec-wireguard";

    # Cloud provider infrastructure (bac_cloud-)
    cloudflare.url = "path:./bac_cloud-cloudflare";
    gcloud.url = "path:./bac_cloud-gcloud";
    oci.url = "path:./bac_cloud-oci";
  };

  outputs = { self, nixpkgs, ... }@inputs: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};

    # VM to services mapping
    vmServices = {
      # Oracle Free Micro 1 - Mail Server
      oci-f-micro_1 = {
        ip = "130.110.251.193";
        services = [ "mailu" "radicale" "syncthing" "syslog-forwarder" "smtp-proxy" ];
      };

      # Oracle Free Micro 2 - Analytics
      oci-f-micro_2 = {
        ip = "129.151.228.66";
        services = [ "matomo" "syslog-forwarder" ];
      };

      # GCloud Free Micro 1 - Central Proxy
      gcp-f-micro_1 = {
        ip = "35.226.147.64";
        services = [ "npm" "authelia" "flask-api" "vaultwarden" "ntfy" "syslog-central" "c3-collector" "github-rss" "palantir-cron" ];
      };

      # Oracle Paid Flex 1 - Heavy Services (Wake-on-Demand)
      oci-p-flex_1 = {
        ip = "144.24.196.72";
        services = [ "photoprism" "nocodb" "code-server" "affine" ];
      };
    };

  in {
    # Export all individual service packages
    packages.${system} = {
      # Application services
      affine = inputs.affine.packages.${system}.default;
      code-server = inputs.code-server.packages.${system}.default;
      github-rss = inputs.github-rss.packages.${system}.default;
      nocodb = inputs.nocodb.packages.${system}.default;
      ntfy = inputs.ntfy.packages.${system}.default;
      photoprism = inputs.photoprism.packages.${system}.default;
      radicale = inputs.radicale.packages.${system}.default;
      syncthing = inputs.syncthing.packages.${system}.default;

      # Backend tools
      c3-collector = inputs.c3-collector.packages.${system}.default;
      flask-api = inputs.flask-api.packages.${system}.default;
      mailu = inputs.mailu.packages.${system}.default;
      matomo = inputs.matomo.packages.${system}.default;
      npm = inputs.npm.packages.${system}.default;
      palantir-cron = inputs.palantir-cron.packages.${system}.default;
      redis = inputs.redis.packages.${system}.default;
      smtp-proxy = inputs.smtp-proxy.packages.${system}.default;
      syslog = inputs.syslog.packages.${system}.default;

      # Backend security
      authelia = inputs.authelia.packages.${system}.default;
      introspect-proxy = inputs.introspect-proxy.packages.${system}.default;
      sauron-lite = inputs.sauron-lite.packages.${system}.default;
      vaultwarden = inputs.vaultwarden.packages.${system}.default;
      wireguard = inputs.wireguard.packages.${system}.default;

      # Cloud provider infrastructure (Terraform)
      cloudflare = inputs.cloudflare.packages.${system}.default;
      gcloud = inputs.gcloud.packages.${system}.default;
      oci = inputs.oci.packages.${system}.default;

      # Build all configs
      all = pkgs.runCommand "all-configs" {} ''
        mkdir -p $out/{app,bac_tools,bac_sec,bac_cloud}

        # Applications
        ln -s ${inputs.affine.packages.${system}.default} $out/app/affine
        ln -s ${inputs.code-server.packages.${system}.default} $out/app/code-server
        ln -s ${inputs.github-rss.packages.${system}.default} $out/app/github-rss
        ln -s ${inputs.nocodb.packages.${system}.default} $out/app/nocodb
        ln -s ${inputs.ntfy.packages.${system}.default} $out/app/ntfy
        ln -s ${inputs.photoprism.packages.${system}.default} $out/app/photoprism
        ln -s ${inputs.radicale.packages.${system}.default} $out/app/radicale
        ln -s ${inputs.syncthing.packages.${system}.default} $out/app/syncthing

        # Backend tools
        ln -s ${inputs.c3-collector.packages.${system}.default} $out/bac_tools/c3-collector
        ln -s ${inputs.flask-api.packages.${system}.default} $out/bac_tools/flask-api
        ln -s ${inputs.mailu.packages.${system}.default} $out/bac_tools/mailu
        ln -s ${inputs.matomo.packages.${system}.default} $out/bac_tools/matomo
        ln -s ${inputs.npm.packages.${system}.default} $out/bac_tools/npm
        ln -s ${inputs.palantir-cron.packages.${system}.default} $out/bac_tools/palantir-cron
        ln -s ${inputs.redis.packages.${system}.default} $out/bac_tools/redis
        ln -s ${inputs.smtp-proxy.packages.${system}.default} $out/bac_tools/smtp-proxy
        ln -s ${inputs.syslog.packages.${system}.default} $out/bac_tools/syslog

        # Backend security
        ln -s ${inputs.authelia.packages.${system}.default} $out/bac_sec/authelia
        ln -s ${inputs.introspect-proxy.packages.${system}.default} $out/bac_sec/introspect-proxy
        ln -s ${inputs.sauron-lite.packages.${system}.default} $out/bac_sec/sauron-lite
        ln -s ${inputs.vaultwarden.packages.${system}.default} $out/bac_sec/vaultwarden
        ln -s ${inputs.wireguard.packages.${system}.default} $out/bac_sec/wireguard

        # Cloud providers (Terraform)
        ln -s ${inputs.cloudflare.packages.${system}.default} $out/bac_cloud/cloudflare
        ln -s ${inputs.gcloud.packages.${system}.default} $out/bac_cloud/gcloud
        ln -s ${inputs.oci.packages.${system}.default} $out/bac_cloud/oci
      '';

      # Deploy script
      deploy = pkgs.writeShellScriptBin "deploy-cloud" ''
        set -e

        APP_SERVICES="affine code-server github-rss nocodb ntfy photoprism radicale syncthing"
        TOOLS_SERVICES="c3-collector flask-api mailu matomo npm palantir-cron redis smtp-proxy syslog"
        SEC_SERVICES="authelia introspect-proxy sauron-lite vaultwarden wireguard"
        CLOUD_SERVICES="cloudflare gcloud oci"

        case "$1" in
          build)
            echo "Building all service configs..."
            nix build .#all
            echo "Configs built in ./result/"
            echo ""
            echo "Structure:"
            echo "  result/app/       - Application services"
            echo "  result/bac_tools/ - Backend tools"
            echo "  result/bac_sec/   - Security services"
            echo "  result/bac_cloud/ - Cloud provider configs (Terraform)"
            ;;
          list)
            echo "Application services (app_):"
            for s in $APP_SERVICES; do echo "  - $s"; done
            echo ""
            echo "Backend tools (bac_tools-):"
            for s in $TOOLS_SERVICES; do echo "  - $s"; done
            echo ""
            echo "Security services (bac_sec-):"
            for s in $SEC_SERVICES; do echo "  - $s"; done
            echo ""
            echo "Cloud providers (bac_cloud-):"
            for s in $CLOUD_SERVICES; do echo "  - $s (Terraform)"; done
            ;;
          *)
            echo "Usage: deploy-cloud [build|list]"
            echo ""
            echo "To build a single service:"
            echo "  nix build .#<service-name>"
            echo ""
            echo "To build all:"
            echo "  nix build .#all"
            ;;
        esac
      '';
    };

    # Development shell
    devShells.${system}.default = pkgs.mkShell {
      packages = [
        pkgs.docker-compose
        pkgs.rsync
        pkgs.openssh
        pkgs.opentofu
        self.packages.${system}.deploy
      ];
    };
  };
}
