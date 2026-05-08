    @bearer header Authorization Bearer*
    handle @bearer {
  @BEARER_BLOCK@
      reverse_proxy @UPSTREAM@ {
        @TRANSPORT_BLOCK@
      }
    }
    handle {
  @AUTHELIA_BLOCK@
      reverse_proxy @UPSTREAM@ {
        @TRANSPORT_BLOCK@
      }
    }
