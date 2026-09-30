    @bearer header Authorization Bearer*
    handle @bearer {
  @BEARER_BLOCK@@BEARER_IDENTITY@
      reverse_proxy @UPSTREAM@ {
        header_up X-Real-IP {http.request.remote.host}@BEARER_HEADER_UP@
@EMPTY_GUARD@
      }
    }
    handle {
  @AUTHELIA_BLOCK@@AUTHELIA_IDENTITY@
      reverse_proxy @UPSTREAM@ {
        header_up X-Real-IP {http.request.remote.host}@AUTHELIA_HEADER_UP@
@EMPTY_GUARD@
      }
    }
