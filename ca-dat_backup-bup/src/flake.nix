{
  description = "Bup - Git-based backup server for database dumps (SSH receiver)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    docker = import ../../_shared/docker.nix;

    config = {
      container_name = "bup-server";
      ssh_port = 2223;
    };

    title = "Bup - Git-based backup server for database dumps (SSH receiver)";

    # GHCR image: wraps alpine with authorized_keys baked in
    ghcr = docker.mkGhcrBuild {
      name = "backup-bup";
      fromImage = "alpine:3.20";
      configFiles = [
        { src = "authorized_keys"; dst = "/root/.ssh/authorized_keys"; }
      ];
    };

    mkDockerCompose = pkgs: docker.mkCompose pkgs {
      banner = docker.banner "~/git/cloud/a_solutions/ca-dat_backup-bup/src/flake.nix";

      services.bup = docker.mkService {
        name = "bup";
        image = ghcr.image;
        build = ghcr.build;
        container_name = config.container_name;
        restart = "no";  # container-init handles startup
        networkMode = "host";
        command = ''
          sh -c "apk add --no-cache restic openssh-server && mkdir -p /backup/databases /root/.ssh && chmod 700 /root/.ssh && ssh-keygen -A && echo 'PermitRootLogin prohibit-password' >> /etc/ssh/sshd_config && /usr/sbin/sshd -D -p ${toString config.ssh_port}"'';
        volumes = [
          "bup_data:/backup/databases"
        ];
        skipReadOnly = true;
        skipSecurity = true;
      };

      volumes = {
        bup_data = {
          driver = "local";
          driver_opts = {
            type = "none";
            o = "bind";
            device = "/backup/databases";
          };
        };
      };
    };

    mkDocs = pkgs: defaultPkg: docker.mkDocs pkgs {
      inherit title config defaultPkg;
    };

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in let
      defaultPkg = pkgs.runCommand "backup-bup-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${./authorized_keys} $out/authorized_keys
      '';
    in {
      default = defaultPkg;
      docs = mkDocs pkgs defaultPkg;
    });
  };
}
