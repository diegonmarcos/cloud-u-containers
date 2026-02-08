{
  description = "Borg - Binary backup server for media files (SSH receiver)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      container_name = "borg-server";
      ssh_port = 2224;
    };

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      # Borg - Binary backup for media/large files
      # Deploy to: oci-p-flex_1
      # SSH server for borg clients

      services:
        borg:
          image: alpine:3.19
          container_name: ${config.container_name}
          restart: unless-stopped
          command: >
            sh -c "
              apk add --no-cache borgbackup openssh-server &&
              mkdir -p /backup/media /root/.ssh &&
              chmod 700 /root/.ssh &&
              ssh-keygen -A &&
              echo 'PermitRootLogin prohibit-password' >> /etc/ssh/sshd_config &&
              /usr/sbin/sshd -D
            "
          volumes:
            - borg_data:/backup/media
            - ./authorized_keys:/root/.ssh/authorized_keys:ro
          ports:
            - "${toString config.ssh_port}:22"
          networks:
            - backup_network

      volumes:
        borg_data:
          driver: local
          driver_opts:
            type: none
            o: bind
            device: /backup/media

      networks:
        backup_network:
          external: true
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "backup-borg-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${./authorized_keys} $out/authorized_keys
      '';
    });
  };
}
