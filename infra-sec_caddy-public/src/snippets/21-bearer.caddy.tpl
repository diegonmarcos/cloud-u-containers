    forward_auth @INTROSPECT_UPSTREAM@ {
      method GET
      uri @INTROSPECT_URI@
      copy_headers @INTROSPECT_COPY@
    }