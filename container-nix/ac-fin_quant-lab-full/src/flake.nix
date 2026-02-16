{
  description = "Quant Lab Full - Research + Analytics + ML + Risk + Trading + Postgres";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      research_image = "quay.io/jupyter/scipy-notebook:latest";
      analytics_image = "python:3.12-slim";
      ml_image = "pytorch/pytorch:latest";
      risk_image = "python:3.12-slim";
      engine_image = "python:3.12-slim";
      db_image = "postgres:16-alpine";
      jupyter_port = 8888;
      dash_port = 8050;
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
            - shared_data:/home/jovyan/data
          environment:
            JUPYTER_ENABLE_LAB: "yes"
          command: >
            sh -c "pip install openbb polars plotly &&
                   start-notebook.sh --NotebookApp.token='''"
          networks:
            - quant_network
          healthcheck:
            test: ["CMD-SHELL", "curl -sf http://localhost:8888/api || exit 1"]
            interval: 30s
            timeout: 10s
            retries: 3
            start_period: 60s

        analytics:
          image: ${config.analytics_image}
          container_name: quant_analytics
          restart: unless-stopped
          ports:
            - "${toString config.dash_port}:8050"
          volumes:
            - ./scripts:/app
            - shared_data:/data
          working_dir: /app
          command: >
            sh -c "pip install polars numpy scipy pandas matplotlib seaborn plotly dash &&
                   tail -f /dev/null"
          networks:
            - quant_network

        ml_brain:
          image: ${config.ml_image}
          container_name: quant_ml
          restart: unless-stopped
          volumes:
            - ./models:/workspace/models
            - shared_data:/data
          working_dir: /workspace
          # Uncomment for GPU support:
          # deploy:
          #   resources:
          #     reservations:
          #       devices:
          #         - driver: nvidia
          #           count: 1
          #           capabilities: [gpu]
          command: >
            sh -c "pip install scikit-learn lightgbm pycaret xgboost &&
                   tail -f /dev/null"
          networks:
            - quant_network

        risk_manager:
          image: ${config.risk_image}
          container_name: quant_risk
          restart: unless-stopped
          volumes:
            - ./risk_reports:/reports
            - shared_data:/data
          working_dir: /reports
          command: >
            sh -c "pip install riskfolio-lib quantstats cvxpy &&
                   tail -f /dev/null"
          networks:
            - quant_network

        execution_engine:
          image: ${config.engine_image}
          container_name: nautilus_engine
          restart: unless-stopped
          ports:
            - "${toString config.engine_port}:5000"
          volumes:
            - ./strategies:/app/strategies
            - shared_data:/data
          working_dir: /app
          command: >
            sh -c "pip install nautilus_trader ib_insync &&
                   tail -f /dev/null"
          networks:
            - quant_network

        database:
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
            - pg_data:/var/lib/postgresql/data
          networks:
            - quant_network
          healthcheck:
            test: ["CMD-SHELL", "pg_isready -U ''${POSTGRES_USER} -d ''${POSTGRES_DB}"]
            interval: 10s
            timeout: 5s
            retries: 5
            start_period: 10s

      volumes:
        pg_data:
          name: quant_full_pg_data
        shared_data:
          name: quant_full_shared_data

      networks:
        quant_network:
          name: quant_full_network
          driver: bridge
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.''${system};
    in {
      default = pkgs.runCommand "quant-lab-full-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
      '';
    });
  };
}
