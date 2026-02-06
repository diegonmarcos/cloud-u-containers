{
  description = "Syslog-ng Central Logging - Docker Compose configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};

    config = {
      image = "balabit/syslog-ng:4.4.0";
      timezone = "Europe/Madrid";
      central_port = 514;
    };

    # Central syslog server (on gcp-f-micro_1)
    dockerComposeCentral = pkgs.writeText "docker-compose-central.yml" ''
      

      services:
        syslog-central:
          image: ${config.image}
          container_name: syslog-central
          restart: unless-stopped
          environment:
            TZ: ${config.timezone}
          ports:
            - "${toString config.central_port}:514/udp"
            - "${toString config.central_port}:514/tcp"
          volumes:
            - ./config/syslog-ng.conf:/etc/syslog-ng/syslog-ng.conf:ro
            - ./logs:/var/log/remote
          networks:
            - proxy

      networks:
        proxy:
          external: true
    '';

    # Forwarder (on each remote VM)
    dockerComposeForwarder = pkgs.writeText "docker-compose-forwarder.yml" ''
      

      services:
        syslog-forwarder:
          image: ${config.image}
          container_name: syslog-forwarder
          restart: unless-stopped
          environment:
            TZ: ${config.timezone}
          volumes:
            - ./config/syslog-ng-forwarder.conf:/etc/syslog-ng/syslog-ng.conf:ro
            - /var/log:/var/log/host:ro
          networks:
            - proxy

      networks:
        proxy:
          external: true
    '';

    # Central server config
    syslogCentralConf = pkgs.writeText "syslog-ng.conf" ''
      @version: 4.4
      @include "scl.conf"

      options {
        time-reap(30);
        mark-freq(10);
        keep-hostname(yes);
        chain-hostnames(no);
      };

      source s_net {
        network(
          transport("udp")
          port(514)
        );
        network(
          transport("tcp")
          port(514)
        );
      };

      destination d_remote {
        file("/var/log/remote/$HOST/$YEAR-$MONTH-$DAY.log"
          create-dirs(yes)
          perm(0644)
          dir-perm(0755)
        );
      };

      log {
        source(s_net);
        destination(d_remote);
      };
    '';

    # Forwarder config (sends to central)
    syslogForwarderConf = pkgs.writeText "syslog-ng-forwarder.conf" ''
      @version: 4.4
      @include "scl.conf"

      options {
        time-reap(30);
        chain-hostnames(no);
        keep-hostname(yes);
      };

      source s_local {
        file("/var/log/host/syslog");
        file("/var/log/host/auth.log");
        file("/var/log/host/kern.log");
      };

      # Change this IP to your central syslog server
      destination d_central {
        network("10.0.0.1" transport("tcp") port(514));
      };

      log {
        source(s_local);
        destination(d_central);
      };
    '';

  in {
    packages.${system} = {
      default = pkgs.runCommand "syslog-configs" {} ''
        mkdir -p $out/{central,forwarder}/config
        mkdir -p $out/central/logs
        cp ${dockerComposeCentral} $out/central/docker-compose.yml
        cp ${syslogCentralConf} $out/central/config/syslog-ng.conf
        cp ${dockerComposeForwarder} $out/forwarder/docker-compose.yml
        cp ${syslogForwarderConf} $out/forwarder/config/syslog-ng-forwarder.conf
      '';
      central = dockerComposeCentral;
      forwarder = dockerComposeForwarder;
    };

    devShells.${system}.default = pkgs.mkShell {
      packages = [ pkgs.docker-compose pkgs.sops pkgs.age ];
    };
  };
}
