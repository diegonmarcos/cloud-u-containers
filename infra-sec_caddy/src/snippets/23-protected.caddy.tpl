    @bearer header Authorization Bearer*
    handle @bearer {
  @BEARER_BLOCK@
      reverse_proxy @UPSTREAM@ {
        header_up X-Real-IP {http.request.remote.host}
@EMPTY_GUARD@
      }
    }
    handle {
  @AUTHELIA_BLOCK@
      reverse_proxy @UPSTREAM@ {
        header_up X-Real-IP {http.request.remote.host}
@EMPTY_GUARD@
      }
    }
