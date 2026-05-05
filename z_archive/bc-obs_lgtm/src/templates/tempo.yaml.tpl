server:
  http_listen_port: @TEMPO_PORT@
  grpc_listen_port: 9112

distributor:
  receivers:
    otlp:
      protocols:
        grpc:
        http:

storage:
  trace:
    backend: local
    local:
      path: /var/tempo/traces
    wal:
      path: /var/tempo/wal
