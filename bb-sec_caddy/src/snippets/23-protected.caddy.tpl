    @bearer header Authorization Bearer*
    handle @bearer {
  @BEARER_BLOCK@
      reverse_proxy @UPSTREAM@
    }
    handle {
  @AUTHELIA_BLOCK@
      reverse_proxy @UPSTREAM@
    }
