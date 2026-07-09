  @SERVICE@ {
    bind 10.0.0.1
    tls internal
    reverse_proxy @UPSTREAM@ {
@EMPTY_GUARD@
    }
@HANDLE_ERRORS@
  }
