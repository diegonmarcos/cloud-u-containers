    forward_auth @INTROSPECT_UPSTREAM@ {
      # A websocket upgrade must not reach the auth subrequest: an introspect/authelia
      # backend that gets Connection: Upgrade never answers and the edge hangs.
      header_up -Connection
      header_up -Upgrade
      method GET
      uri @INTROSPECT_URI@
      copy_headers @INTROSPECT_COPY@
    }