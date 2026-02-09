{
  description = "Fluent Bit - Log processor and forwarder";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      container_name = "fluent-bit";
      image = "fluent/fluent-bit:latest";
    };

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      services:
        fluent-bit:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: unless-stopped
          volumes:
            - /opt/fluent-bit/fluent-bit.conf:/fluent-bit/etc/fluent-bit.conf:ro
            - /opt/fluent-bit/parsers.conf:/fluent-bit/etc/parsers.conf:ro
            - /var/lib/docker/containers:/var/lib/docker/containers:ro
            - /var/log:/var/log:ro
            - fluent-bit-db:/fluent-bit/db
          networks:
            - dev_network

      networks:
        dev_network:
          external: true

      volumes:
        fluent-bit-db:
          driver: local
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "fluent-bit-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
      '';
    });
  };
}
