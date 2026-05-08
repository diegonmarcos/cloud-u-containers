  @SERVICE@ {
    bind 10.0.0.1
    tls internal {
      on_demand
    }
    respond "@PLACEHOLDER_MSG@" 204
  }
