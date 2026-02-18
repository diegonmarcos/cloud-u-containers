{
  description = "Syslog-ng Central Logging - Docker Compose configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      image = "balabit/syslog-ng:4.4.0";
      timezone = "Europe/Madrid";
      central_port = 514;
    };

    # Central syslog server (on gcp-f-micro_1)
    mkDockerComposeCentral = pkgs: pkgs.writeText "docker-compose-central.yml" ''
      

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
    mkDockerComposeForwarder = pkgs: pkgs.writeText "docker-compose-forwarder.yml" ''
      

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
    mkSyslogCentralConf = pkgs: pkgs.writeText "syslog-ng.conf" ''
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
    mkSyslogForwarderConf = pkgs: pkgs.writeText "syslog-ng-forwarder.conf" ''
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
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "syslog-configs" {} ''
        mkdir -p $out
        cp ${mkDockerComposeCentral pkgs} $out/docker-compose.yml
        cp ${mkDockerComposeForwarder pkgs} $out/docker-compose-forwarder.yml
        mkdir -p $out/config
        cp ${mkSyslogCentralConf pkgs} $out/config/syslog-ng.conf
        cp ${mkSyslogForwarderConf pkgs} $out/config/syslog-ng-forwarder.conf
      '';
    });
  };
}
