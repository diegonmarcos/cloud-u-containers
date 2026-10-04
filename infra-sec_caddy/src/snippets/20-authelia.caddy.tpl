    forward_auth @AUTHELIA_UPSTREAM@ {
      uri @AUTHELIA_URI@
      header_up X-Forwarded-Uri {http.request.orig_uri}
      copy_headers @AUTHELIA_COPY@
    }
