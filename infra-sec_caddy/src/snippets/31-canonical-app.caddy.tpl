  @SERVICE@ {
    bind 10.0.0.1
    tls internal {
      on_demand
    }
    reverse_proxy @UPSTREAM@ {
@EMPTY_GUARD@
    }
@HANDLE_ERRORS@
  }
