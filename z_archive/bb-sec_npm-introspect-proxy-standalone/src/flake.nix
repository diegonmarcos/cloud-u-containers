{
  description = "Introspect Proxy - Authelia Token Introspection Proxy";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      container_name = "introspect-proxy";
      image = "introspect-proxy:latest";
      port = 4182;
      timezone = "Europe/Madrid";

      # Authelia OIDC config
      introspect_url = "http://authelia:9091/authelia/api/oidc/introspection";
      client_id = "cli";
      # CLIENT_SECRET read from .env via docker-compose env_file
      client_secret_env = "AUTHELIA_CLI_SECRET";
    };

    # Dockerfile for building the proxy
    mkDockerfile = pkgs: pkgs.writeText "Dockerfile" ''
      FROM python:3.11-slim-bookworm

      WORKDIR /app

      RUN pip install --no-cache-dir flask requests gunicorn

      COPY app.py .

      EXPOSE 4182

      CMD ["gunicorn", "-b", "0.0.0.0:4182", "-w", "1", "--timeout", "120", "app:app"]
    '';

    # Simple Flask proxy app
    mkAppPy = pkgs: pkgs.writeText "app.py" ''
      import os
      import requests
      from flask import Flask, request, jsonify

      app = Flask(__name__)

      INTROSPECT_URL = os.environ.get('INTROSPECT_URL')
      CLIENT_ID = os.environ.get('CLIENT_ID')
      CLIENT_SECRET = os.environ.get('CLIENT_SECRET')
      DEBUG = os.environ.get('DEBUG', 'false').lower() == 'true'

      @app.route('/health')
      def health():
          return jsonify({'status': 'ok'})

      @app.route('/introspect', methods=['POST'])
      def introspect():
          auth_header = request.headers.get('Authorization', "")
          if not auth_header.startswith('Bearer '):
              return jsonify({'active': False, 'error': 'No bearer token'}), 401

          token = auth_header[7:]

          try:
              resp = requests.post(
                  INTROSPECT_URL,
                  data={'token': token},
                  auth=(CLIENT_ID, CLIENT_SECRET),
                  timeout=5
              )
              return jsonify(resp.json()), resp.status_code
          except Exception as e:
              if DEBUG:
                  return jsonify({'active': False, 'error': str(e)}), 500
              return jsonify({'active': False}), 500

      @app.route('/auth', methods=['GET'])
      def auth():
          """NPM forward-auth compatible endpoint"""
          auth_header = request.headers.get('Authorization', "")
          if not auth_header.startswith('Bearer '):
              return "", 401

          token = auth_header[7:]

          try:
              resp = requests.post(
                  INTROSPECT_URL,
                  data={'token': token},
                  auth=(CLIENT_ID, CLIENT_SECRET),
                  timeout=5
              )
              data = resp.json()
              if data.get('active'):
                  return "", 200
              return "", 401
          except:
              return "", 401

      if __name__ == '__main__':
          app.run(host='0.0.0.0', port=4182, debug=DEBUG)
    '';

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      services:
        introspect-proxy:
          build: .
          image: ${config.image}
          container_name: ${config.container_name}
          restart: unless-stopped
          env_file:
            - .env
          ports:
            - "127.0.0.1:${toString config.port}:4182"
          environment:
            TZ: ${config.timezone}
            INTROSPECT_URL: ${config.introspect_url}
            CLIENT_ID: ${config.client_id}
            CLIENT_SECRET: ''\${${config.client_secret_env}}
            DEBUG: "false"
          networks:
            - npm_default
          deploy:
            resources:
              limits:
                memory: 96M
              reservations:
                memory: 48M
          healthcheck:
            test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:4182/health"]
            interval: 30s
            timeout: 5s
            retries: 3
            start_period: 10s

      networks:
        npm_default:
          external: true
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "introspect-proxy-configs" {} ''
        mkdir -p $out/app $out/npm-configs
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${./Dockerfile} $out/Dockerfile
        cp ${./app/main.py} $out/app/main.py
        cp ${./app/requirements.txt} $out/app/requirements.txt
        cp -r ${./npm-configs}/* $out/npm-configs/
      '';
    });
  };
}
