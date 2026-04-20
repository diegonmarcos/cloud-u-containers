{
  description = "Borg - Binary backup server for media files (SSH receiver)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    docker = import ../../_shared/docker.nix;
    ports = import ../../_shared/lib/port-enforcement.nix { buildJsonPath = ../build.json; };

    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    # Single source of truth: build-borg-server.json (symlink → I_cloud-data/
    # build-borg-server.json). Engine resolves symlink before nix build.
    buildBorg = builtins.fromJSON (builtins.readFile ./build-borg-server.json);

    config = {
      container_name = buildBorg.container.container_name;
      ssh_port = ports.valueOf "app";
    };

    title = "Borg - Binary backup server for media files (SSH receiver)";

    # GHCR image: wraps alpine with authorized_keys baked in
    ghcr = docker.mkGhcrBuild {
      name = "backup-borg";
      fromImage = buildJson.upstream_image;
      configFiles = [
        { src = "authorized_keys"; dst = "/root/.ssh/authorized_keys"; }
      ];
    };

    mkDockerCompose = pkgs: docker.mkCompose pkgs {
      banner = docker.banner "~/git/cloud/a_solutions/ca-dat_backup-borg/src/flake.nix";

      services.borg = docker.mkService {
        name = "borg";
        image = ghcr.image;
        build = ghcr.build;
        container_name = config.container_name;
        restart = "no";
        networkMode = "host";
        command = ''
          sh -c "apk add --no-cache borgbackup openssh-server && mkdir -p /backup/media /root/.ssh && chmod 700 /root/.ssh && ssh-keygen -A && echo 'PermitRootLogin prohibit-password' >> /etc/ssh/sshd_config && /usr/sbin/sshd -D -p ${toString config.ssh_port}"'';
        volumes = [
          "borg_data:/backup/media"
        ];
        skipReadOnly = true;
        skipSecurity = true;
      };

      volumes = {
        borg_data = {
          driver = "local";
          driver_opts = {
            type = "none";
            o = "bind";
            device = "/backup/media";
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
      defaultPkg = pkgs.runCommand "backup-borg-configs" {} ''
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
