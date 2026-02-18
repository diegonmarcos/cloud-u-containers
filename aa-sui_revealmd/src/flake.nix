{
  description = "RevealMD - Markdown to reveal.js presentations";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      domain = "slides.diegonmarcos.com";
      container_name = "revealmd_app";
      image = "webpronl/reveal-md:latest";
      port = 3014;
    };

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      # RevealMD - Markdown to reveal.js presentations
      # Deployed on: oci-A1-f_1 (Oracle Flex)

      services:
        revealmd:
          image: ${config.image}
          container_name: ${config.container_name}
          restart: "no"
          ports:
            - "10.0.0.2:${toString config.port}:1948"
          volumes:
            - slides_data:/slides
          command: /slides --watch
          networks:
            - dev_network
          healthcheck:
            test: ['CMD', 'wget', '-q', '--spider', 'http://localhost:1948']
            interval: 30s
            timeout: 10s
            retries: 3

      networks:
        dev_network:
          external: true
          name: dev_network

      volumes:
        slides_data:
          driver: local
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "revealmd-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
      '';
    });
  };
}
