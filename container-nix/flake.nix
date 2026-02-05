{
  description = "Cloud Infrastructure - All Docker services managed with Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

    # Suite services (aa-sui_)
    affine.url = "path:./aa-sui_affine";
    code-server.url = "path:./aa-sui_code-server";
    gitea.url = "path:./aa-sui_gitea";
    mailu.url = "path:./aa-sui_tools-mailu";
    photoprism.url = "path:./aa-sui_photoprism";
    radicale.url = "path:./aa-sui_radicale";
    smtp-proxy.url = "path:./aa-sui_tools-smtp-proxy";

    # Misc tools (ab-mic_)
    syncthing.url = "path:./ab-mic_syncthing";
    vaultwarden.url = "path:./ab-mic_vaultwarden";

    # Cloud providers (ba-clo_)
    cloudflare.url = "path:./ba-clo_cloudflare";
    gcloud.url = "path:./ba-clo_gcloud";
    oci.url = "path:./ba-clo_oci";

    # Security (bb-sec_)
    authelia.url = "path:./bb-sec_authelia";
    flask-api.url = "path:./bb-sec_flask-api";
    npm.url = "path:./bb-sec_npm";
    npm-introspect-proxy.url = "path:./bb-sec_npm-introspect-proxy";
    wireguard.url = "path:./bb-sec_wireguard";

    # Observability (bc-obs_)
    c3-collector.url = "path:./bc-obs_c3-collector";
    github-rss.url = "path:./bc-obs_github-rss";
    matomo.url = "path:./bc-obs_matomo";
    nocodb.url = "path:./bc-obs_nocodb";
    ntfy.url = "path:./bc-obs_ntfy";
    palantir-cron.url = "path:./bc-obs_palantir-cron";
    sauron-lite.url = "path:./bc-obs_sauron-lite";
    syslog.url = "path:./bc-obs_syslog";

    # Databases & Backups (ca-dat_)
    redis.url = "path:./ca-dat_redis";
    backup-bup.url = "path:./ca-dat_backup-bup";
    backup-borg.url = "path:./ca-dat_backup-borg";
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
        services = [ "photoprism" "nocodb" "code-server" "affine" "gitea" "backup-bup" "backup-borg" ];
      };
    };

  in {
    # Export all individual service packages
    packages.${system} = {
      # Suite services (aa-sui_)
      affine = inputs.affine.packages.${system}.default;
      code-server = inputs.code-server.packages.${system}.default;
      gitea = inputs.gitea.packages.${system}.default;
      mailu = inputs.mailu.packages.${system}.default;
      photoprism = inputs.photoprism.packages.${system}.default;
      radicale = inputs.radicale.packages.${system}.default;
      smtp-proxy = inputs.smtp-proxy.packages.${system}.default;

      # Misc tools (ab-mic_)
      syncthing = inputs.syncthing.packages.${system}.default;
      vaultwarden = inputs.vaultwarden.packages.${system}.default;

      # Cloud providers (ba-clo_)
      cloudflare = inputs.cloudflare.packages.${system}.default;
      gcloud = inputs.gcloud.packages.${system}.default;
      oci = inputs.oci.packages.${system}.default;

      # Security (bb-sec_)
      authelia = inputs.authelia.packages.${system}.default;
      flask-api = inputs.flask-api.packages.${system}.default;
      npm = inputs.npm.packages.${system}.default;
      npm-introspect-proxy = inputs.npm-introspect-proxy.packages.${system}.default;
      wireguard = inputs.wireguard.packages.${system}.default;

      # Observability (bc-obs_)
      c3-collector = inputs.c3-collector.packages.${system}.default;
      github-rss = inputs.github-rss.packages.${system}.default;
      matomo = inputs.matomo.packages.${system}.default;
      nocodb = inputs.nocodb.packages.${system}.default;
      ntfy = inputs.ntfy.packages.${system}.default;
      palantir-cron = inputs.palantir-cron.packages.${system}.default;
      sauron-lite = inputs.sauron-lite.packages.${system}.default;
      syslog = inputs.syslog.packages.${system}.default;

      # Databases & Backups (ca-dat_)
      redis = inputs.redis.packages.${system}.default;
      backup-bup = inputs.backup-bup.packages.${system}.default;
      backup-borg = inputs.backup-borg.packages.${system}.default;

      # Build all configs
      all = pkgs.runCommand "all-configs" {} ''
        mkdir -p $out/{aa-sui,ab-mic,ba-clo,bb-sec,bc-obs,ca-dat}

        # Suite services (aa-sui_)
        ln -s ${inputs.affine.packages.${system}.default} $out/aa-sui/affine
        ln -s ${inputs.code-server.packages.${system}.default} $out/aa-sui/code-server
        ln -s ${inputs.gitea.packages.${system}.default} $out/aa-sui/gitea
        ln -s ${inputs.mailu.packages.${system}.default} $out/aa-sui/mailu
        ln -s ${inputs.photoprism.packages.${system}.default} $out/aa-sui/photoprism
        ln -s ${inputs.radicale.packages.${system}.default} $out/aa-sui/radicale
        ln -s ${inputs.smtp-proxy.packages.${system}.default} $out/aa-sui/smtp-proxy

        # Misc tools (ab-mic_)
        ln -s ${inputs.syncthing.packages.${system}.default} $out/ab-mic/syncthing
        ln -s ${inputs.vaultwarden.packages.${system}.default} $out/ab-mic/vaultwarden

        # Cloud providers (ba-clo_)
        ln -s ${inputs.cloudflare.packages.${system}.default} $out/ba-clo/cloudflare
        ln -s ${inputs.gcloud.packages.${system}.default} $out/ba-clo/gcloud
        ln -s ${inputs.oci.packages.${system}.default} $out/ba-clo/oci

        # Security (bb-sec_)
        ln -s ${inputs.authelia.packages.${system}.default} $out/bb-sec/authelia
        ln -s ${inputs.flask-api.packages.${system}.default} $out/bb-sec/flask-api
        ln -s ${inputs.npm.packages.${system}.default} $out/bb-sec/npm
        ln -s ${inputs.npm-introspect-proxy.packages.${system}.default} $out/bb-sec/npm-introspect-proxy
        ln -s ${inputs.wireguard.packages.${system}.default} $out/bb-sec/wireguard

        # Observability (bc-obs_)
        ln -s ${inputs.c3-collector.packages.${system}.default} $out/bc-obs/c3-collector
        ln -s ${inputs.github-rss.packages.${system}.default} $out/bc-obs/github-rss
        ln -s ${inputs.matomo.packages.${system}.default} $out/bc-obs/matomo
        ln -s ${inputs.nocodb.packages.${system}.default} $out/bc-obs/nocodb
        ln -s ${inputs.ntfy.packages.${system}.default} $out/bc-obs/ntfy
        ln -s ${inputs.palantir-cron.packages.${system}.default} $out/bc-obs/palantir-cron
        ln -s ${inputs.sauron-lite.packages.${system}.default} $out/bc-obs/sauron-lite
        ln -s ${inputs.syslog.packages.${system}.default} $out/bc-obs/syslog

        # Databases & Backups (ca-dat_)
        ln -s ${inputs.redis.packages.${system}.default} $out/ca-dat/redis
        ln -s ${inputs.backup-bup.packages.${system}.default} $out/ca-dat/backup-bup
        ln -s ${inputs.backup-borg.packages.${system}.default} $out/ca-dat/backup-borg
      '';

      # Deploy script
      deploy = pkgs.writeShellScriptBin "deploy-cloud" ''
        set -e

        SUITE_SERVICES="affine code-server gitea mailu photoprism radicale smtp-proxy"
        MISC_SERVICES="syncthing vaultwarden"
        CLOUD_SERVICES="cloudflare gcloud oci"
        SEC_SERVICES="authelia flask-api npm npm-introspect-proxy wireguard"
        OBS_SERVICES="c3-collector github-rss matomo nocodb ntfy palantir-cron sauron-lite syslog"
        DATA_SERVICES="redis backup-bup backup-borg"

        case "$1" in
          build)
            echo "Building all service configs..."
            nix build .#all
            echo "Configs built in ./result/"
            echo ""
            echo "Structure:"
            echo "  result/aa-sui/ - Suite services"
            echo "  result/ab-mic/ - Misc tools"
            echo "  result/ba-clo/ - Cloud providers (Terraform)"
            echo "  result/bb-sec/ - Security services"
            echo "  result/bc-obs/ - Observability"
            echo "  result/ca-dat/ - Databases"
            ;;
          list)
            echo "Suite services (aa-sui_):"
            for s in $SUITE_SERVICES; do echo "  - $s"; done
            echo ""
            echo "Misc tools (ab-mic_):"
            for s in $MISC_SERVICES; do echo "  - $s"; done
            echo ""
            echo "Cloud providers (ba-clo_):"
            for s in $CLOUD_SERVICES; do echo "  - $s (Terraform)"; done
            echo ""
            echo "Security services (bb-sec_):"
            for s in $SEC_SERVICES; do echo "  - $s"; done
            echo ""
            echo "Observability (bc-obs_):"
            for s in $OBS_SERVICES; do echo "  - $s"; done
            echo ""
            echo "Databases (ca-dat_):"
            for s in $DATA_SERVICES; do echo "  - $s"; done
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
