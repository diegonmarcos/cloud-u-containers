  @SERVICE@ {
    bind 10.0.0.1
    tls internal
    rewrite * /@BUCKET@{uri}
    reverse_proxy @S3_ENDPOINT@ {
      header_up Host @S3_HOST@
    }
  }
