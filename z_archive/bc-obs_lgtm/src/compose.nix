# compose.nix — pure attrset describing docker-compose.yml for LGTM stack
# (grafana + loki + tempo + mimir). engine.nix serialises it via
# lib.generators.toYAML, merging compose-defaults.json.
{ buildJson, cGrafana, cLoki, cTempo, cMimir, svc }:

let
  ghcrImage = name: "ghcr.io/diegonmarcos/lgtm-${name}:latest";
  lgtmIp    = svc.lgtm.ip;

  grafanaPort = toString buildJson.ports.grafana;
  lokiPort    = toString buildJson.ports.loki;
  tempoPort   = toString buildJson.ports.tempo;
  mimirPort   = toString buildJson.ports.mimir;
in
{
  services = {
    grafana = {
      image          = ghcrImage "grafana";
      container_name = cGrafana.container_name;
      network_mode   = "host";
      environment = {
        GF_SECURITY_ADMIN_USER     = "admin";
        GF_SECURITY_ADMIN_PASSWORD = "\${GRAFANA_ADMIN_PASSWORD:-changeme}";
        GF_USERS_ALLOW_SIGN_UP     = "false";
        GF_SERVER_HTTP_PORT        = grafanaPort;
        GF_SERVER_ROOT_URL         = "https://${buildJson.domain}";
      };
      volumes = [
        "grafana_data:/var/lib/grafana"
        "./configs/datasources.yml:/etc/grafana/provisioning/datasources/datasources.yml:ro"
      ];
      depends_on = [ "loki" ];
      healthcheck = {
        test     = [ "CMD" "wget" "-q" "--spider" "http://localhost:${grafanaPort}/api/health" ];
        interval = "30s";
        timeout  = "10s";
        retries  = 3;
      };
    };

    loki = {
      image          = ghcrImage "loki";
      container_name = cLoki.container_name;
      network_mode   = "host";
      volumes = [
        "loki_data:/loki"
        "/home/ubuntu/bin/busybox-static:/usr/local/bin/busybox:ro"
      ];
      command = "-config.file=/etc/loki/local-config.yaml -server.http-listen-address=${lgtmIp} -server.http-listen-port=${lokiPort} -server.grpc-listen-port=9111";
      healthcheck = {
        test         = [ "CMD" "/usr/local/bin/busybox" "wget" "-qO" "/dev/null" "http://127.0.0.1:${lokiPort}/ready" ];
        interval     = "30s";
        timeout      = "10s";
        retries      = 5;
        start_period = "120s";
      };
    };

    tempo = {
      image          = ghcrImage "tempo";
      container_name = cTempo.container_name;
      network_mode   = "host";
      volumes = [
        "tempo_data:/var/tempo"
        "./configs/tempo.yaml:/etc/tempo/tempo.yaml:ro"
      ];
      command = [ "-config.file=/etc/tempo/tempo.yaml" ];
    };

    mimir = {
      image          = ghcrImage "mimir";
      container_name = cMimir.container_name;
      network_mode   = "host";
      volumes = [
        "mimir_data:/data"
        "./configs/mimir.yaml:/etc/mimir/mimir.yaml:ro"
      ];
      command = [ "-config.file=/etc/mimir/mimir.yaml" "-target=all" ];
    };
  };

  volumes = {
    grafana_data = {};
    loki_data    = {};
    tempo_data   = {};
    mimir_data   = {};
  };
}
