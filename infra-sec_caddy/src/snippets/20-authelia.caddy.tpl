    forward_auth @AUTHELIA_UPSTREAM@ {
      # A websocket upgrade must not reach the auth subrequest: an introspect/authelia
      # backend that gets Connection: Upgrade never answers and the edge hangs.
      header_up -Connection
      header_up -Upgrade
      uri @AUTHELIA_URI@
      header_up X-Forwarded-Uri {http.request.orig_uri}
      copy_headers @AUTHELIA_COPY@
    }
