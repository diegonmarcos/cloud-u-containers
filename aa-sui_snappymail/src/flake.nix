{
  description = "SnappyMail — Lightweight webmail client for Stalwart";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    buildJson = builtins.fromJSON (builtins.readFile ../build.json);

    config = {
      port = toString buildJson.ports.app;
      mail_domain = "mail.diegonmarcos.com";
    };

    title = "SnappyMail";
    docker = import ../../_shared/docker.nix;

    mkDockerCompose = pkgs: docker.mkCompose pkgs {
      banner = docker.banner "~/git/cloud/a_solutions/aa-sui_snappymail/src/flake.nix";
      services = {
        snappymail = docker.mkService {
          name = "snappymail";
          image = "djmaze/snappymail:latest";
          container_name = "snappymail";
          skipReadOnly = true;
          environment = [
            "SNAPPYMAIL_BACKEND_PATH=/var/lib/snappymail"
          ];
          volumes = [
            "./data:/var/lib/snappymail"
          ];
          memLimit = "64M";
          memReservation = "16M";
          healthcheck = {
            test = "['CMD', 'curl', '-sf', 'http://localhost:8888/']";
            interval = "30s";
            timeout = "10s";
            retries = 3;
            start_period = "10s";
          };
        };
      };
    };

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in let
      defaultPkg = pkgs.runCommand "snappymail-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
      '';
    in {
      default = defaultPkg;
      docs = docker.mkDocs pkgs { inherit title config defaultPkg; };
    });
  };
}
