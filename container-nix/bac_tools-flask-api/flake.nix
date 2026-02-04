{
  description = "Cloud API (Flask) - Docker Compose configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};

    config = {
      domain = "api.diegonmarcos.com";
      container_name = "flask-api";
      image = "python:3.11-slim";
      port = 5000;
      timezone = "Europe/Madrid";

      # OCI credentials for wake-on-demand
      oci_user_ocid = "CHANGE_ME";
      oci_tenancy_ocid = "CHANGE_ME";
      oci_region = "eu-marseille-1";
      oci_fingerprint = "CHANGE_ME";
    };

    dockerCompose = pkgs.writeText "docker-compose.yml" ''
      version: "3.8"

      services:
        api:
          build:
            context: .
            dockerfile: Dockerfile
          container_name: ${config.container_name}
          restart: unless-stopped
          environment:
            TZ: ${config.timezone}
            FLASK_ENV: production
            OCI_USER_OCID: ${config.oci_user_ocid}
            OCI_TENANCY_OCID: ${config.oci_tenancy_ocid}
            OCI_REGION: ${config.oci_region}
            OCI_FINGERPRINT: ${config.oci_fingerprint}
          ports:
            - "${toString config.port}:5000"
          volumes:
            - ./app:/app
            - ./oci_config:/root/.oci:ro
          networks:
            - proxy

      networks:
        proxy:
          external: true
    '';

    dockerfile = pkgs.writeText "Dockerfile" ''
      FROM python:3.11-slim

      WORKDIR /app

      RUN pip install --no-cache-dir flask gunicorn oci requests

      COPY app/ /app/

      EXPOSE 5000

      CMD ["gunicorn", "--bind", "0.0.0.0:5000", "app:app"]
    '';

    # Basic Flask app template
    flaskApp = pkgs.writeText "app.py" ''
      from flask import Flask, jsonify
      import os

      app = Flask(__name__)

      @app.route('/api/health')
      def health():
          return jsonify({"status": "ok"})

      @app.route('/api/vms')
      def vms():
          # TODO: Implement OCI VM listing
          return jsonify({"vms": []})

      @app.route('/api/wake/<vm_id>', methods=['POST'])
      def wake(vm_id):
          # TODO: Implement wake-on-demand
          return jsonify({"status": "waking", "vm": vm_id})

      if __name__ == '__main__':
          app.run(host='0.0.0.0', port=5000)
    '';

  in {
    packages.${system} = {
      default = pkgs.runCommand "flask-api-configs" {} ''
        mkdir -p $out/{app,oci_config}
        cp ${dockerCompose} $out/docker-compose.yml
        cp ${dockerfile} $out/Dockerfile
        cp ${flaskApp} $out/app/app.py
      '';
      docker-compose = dockerCompose;
      dockerfile = dockerfile;
    };

    devShells.${system}.default = pkgs.mkShell {
      packages = [ pkgs.docker-compose pkgs.python3 pkgs.python3Packages.flask ];
    };
  };
}
