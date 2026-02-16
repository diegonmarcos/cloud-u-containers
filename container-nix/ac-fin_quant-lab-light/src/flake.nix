{
  description = "Quant Lab Light - Jupyter + NautilusTrader + Postgres";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      research_image = "quay.io/jupyter/scipy-notebook:latest";
      engine_image = "python:3.12-slim";
      db_image = "postgres:16-alpine";
      jupyter_port = 8888;
      engine_port = 5000;
      db_port = 5432;
    };

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      services:
        research:
          image: ${config.research_image}
          container_name: quant_research
          restart: unless-stopped
          ports:
            - "${toString config.jupyter_port}:8888"
          volumes:
            - ./notebooks:/home/jovyan/work
            - ./data:/home/jovyan/data
          environment:
            JUPYTER_ENABLE_LAB: "yes"
            GRANT_SUDO: "yes"
          command: >
            sh -c "pip install polars openbb quantstats riskfolio-lib plotly &&
                   start-notebook.sh --NotebookApp.token=''"
          networks:
            - quant_network
          healthcheck:
            test: ["CMD-SHELL", "curl -sf http://localhost:8888/api || exit 1"]
            interval: 30s
            timeout: 10s
            retries: 3
            start_period: 60s

        engine:
          image: ${config.engine_image}
          container_name: nautilus_engine
          restart: unless-stopped
          ports:
            - "${toString config.engine_port}:5000"
          volumes:
            - ./strategies:/app/strategies
            - ./data:/app/data
          working_dir: /app
          depends_on:
            - research
          command: >
            sh -c "pip install nautilus_trader ib_insync &&
                   tail -f /dev/null"
          networks:
            - quant_network

        db:
          image: ${config.db_image}
          container_name: quant_db
          restart: unless-stopped
          ports:
            - "${toString config.db_port}:5432"
          env_file:
            - .secrets
          environment:
            POSTGRES_USER: ''${POSTGRES_USER}
            POSTGRES_PASSWORD: ''${POSTGRES_PASSWORD}
            POSTGRES_DB: ''${POSTGRES_DB}
          volumes:
            - postgres_data:/var/lib/postgresql/data
          networks:
            - quant_network
          healthcheck:
            test: ["CMD-SHELL", "pg_isready -U ''${POSTGRES_USER} -d ''${POSTGRES_DB}"]
            interval: 10s
            timeout: 5s
            retries: 5
            start_period: 10s

      volumes:
        postgres_data:
          name: quant_light_postgres_data

      networks:
        quant_network:
          name: quant_light_network
          driver: bridge
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.''${system};
    in {
      default = pkgs.runCommand "quant-lab-light-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
      '';
    });
  };
}
