{
  description = "Cloud Go API - Docker Compose configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      domain = "api.diegonmarcos.com";
      container_name = "go-api";
      port = 8090;
    };

    mkDockerCompose = pkgs: pkgs.writeText "docker-compose.yml" ''
      services:
        go-api:
          build: .
          container_name: ${config.container_name}
          restart: unless-stopped
          ports:
            - "127.0.0.1:${toString config.port}:8090"
          volumes:
            - /home/diego/cloud/architecture.json:/app/config/architecture.json:ro
            - ~/.ssh:/home/appuser/.ssh:ro
            - /home/diego/cloud/oci_config:/app/config/oci_config:ro
            - /home/diego/cloud/oci_api_key.pem:/app/config/oci_api_key.pem:ro
            - /home/diego/cloud/gcp_key.json:/app/config/gcp_key.json:ro
          env_file:
            - .secrets
          environment:
            - GO_API_PORT=8090
          networks:
            - npm_default
          healthcheck:
            test: ["CMD", "curl", "-f", "http://localhost:8090/go/health"]
            interval: 30s
            timeout: 10s
            retries: 3
            start_period: 10s

      networks:
        npm_default:
          external: true
    '';

    mkDockerfile = pkgs: pkgs.writeText "Dockerfile" ''
      FROM golang:1.23-alpine AS builder
      WORKDIR /build
      COPY go.mod go.sum ./
      RUN go mod download
      COPY . .
      RUN CGO_ENABLED=0 GOOS=linux go build -o /go-api .

      FROM alpine:3.20
      RUN apk add --no-cache ca-certificates curl openssh-client iputils
      RUN adduser -D -u 1000 appuser
      USER appuser
      WORKDIR /app
      COPY --from=builder /go-api /app/go-api
      EXPOSE 8090
      CMD ["/app/go-api"]
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.''${system};
    in {
      default = pkgs.runCommand "go-api-configs" {} ''
        mkdir -p $out
        cp ${mkDockerCompose pkgs} $out/docker-compose.yml
        cp ${mkDockerfile pkgs} $out/Dockerfile
      '';
    });
  };
}
