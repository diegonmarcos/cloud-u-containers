  @SERVICE@ {
    bind 10.0.0.1
    tls internal {
      on_demand
    }
    respond "DB catalog — container=@CONTAINER@ engine=@ENGINE@ port=@PORT@ upstream=@UPSTREAM@ path=@DB_PATH@ vm=@VM@" 200
  }
