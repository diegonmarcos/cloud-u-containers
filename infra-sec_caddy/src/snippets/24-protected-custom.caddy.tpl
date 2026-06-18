    @bearer header Authorization Bearer*
    handle @bearer {
  @BEARER_BLOCK@
      reverse_proxy @UPSTREAM@ {
        header_up X-Real-IP {http.request.remote.host}
        @TRANSPORT_BLOCK@
      }
    }
    handle {
  @AUTHELIA_BLOCK@
      reverse_proxy @UPSTREAM@ {
        header_up X-Real-IP {http.request.remote.host}
        @TRANSPORT_BLOCK@
      }
    }
