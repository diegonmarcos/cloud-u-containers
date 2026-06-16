    forward_auth @AUTHELIA_UPSTREAM@ {
      uri @AUTHELIA_URI@
      copy_headers @AUTHELIA_COPY@
    }