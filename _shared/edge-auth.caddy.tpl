  (@GATE@) {
    @ea_pre {
      method OPTIONS
      header Access-Control-Request-Method *
    }
    @ea_bearer {
      header Authorization Bearer*
      not path {args[:]}
      not {
        method OPTIONS
        header Access-Control-Request-Method *
      }@EA_EXTRA@@EA_OFFMESH@
    }
    @ea_session {
      not header Authorization Bearer*
      not path {args[:]}
      not {
        method OPTIONS
        header Access-Control-Request-Method *
      }@EA_EXTRA@@EA_OFFMESH@
    }
    respond @ea_pre 204
    forward_auth @ea_bearer @INTROSPECT_UPSTREAM@ {
      method GET
      uri @INTROSPECT_URI@
      copy_headers @INTROSPECT_COPY@
    }
    forward_auth @ea_session @AUTHELIA_UPSTREAM@ {
      uri @AUTHELIA_URI@
      header_up X-Forwarded-Uri {http.request.orig_uri}
      copy_headers @AUTHELIA_COPY@
    }
  }
