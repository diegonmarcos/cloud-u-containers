{
  description = "Bup - Git-based backup server for database dumps (SSH receiver)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      container_name = "bup-server";
      ssh_port = 2223;
    };

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      # bup - Git-based backup for database dumps
      # Deploy to: oci-A1-f_1
      # Receives dumps from all servers via SSH

      services:
        bup:
          image: alpine:3.19
          container_name: ${config.container_name}
          restart: unless-stopped
          command: >
            sh -c "
              apk add --no-cache bup openssh-server &&
              mkdir -p /backup/databases /root/.ssh &&
              chmod 700 /root/.ssh &&
              ssh-keygen -A &&
              echo 'PermitRootLogin prohibit-password' >> /etc/ssh/sshd_config &&
              bup init -r /backup/databases &&
              /usr/sbin/sshd -D
            "
          volumes:
            - bup_data:/backup/databases
            - ./authorized_keys:/root/.ssh/authorized_keys:ro
          ports:
            - "${toString config.ssh_port}:22"
          networks:
            - backup_network

      volumes:
        bup_data:
          driver: local
          driver_opts:
            type: none
            o: bind
            device: /backup/databases

      networks:
        backup_network:
          external: true
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "backup-bup-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${./authorized_keys} $out/authorized_keys
      '';
    });
  };
}
