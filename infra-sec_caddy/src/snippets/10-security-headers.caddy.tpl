  (security_headers) {
    header {
      Strict-Transport-Security "max-age=@HSTS_MAX_AGE@; includeSubDomains; preload"
      X-Content-Type-Options "nosniff"
      X-Frame-Options "@FRAME_OPTIONS@"
      Referrer-Policy "@REFERRER_POLICY@"
      Permissions-Policy "@PERMISSIONS_POLICY@"
      Access-Control-Allow-Origin "@CORS_ORIGIN@"
      Access-Control-Allow-Methods "@CORS_METHODS@"
      Access-Control-Allow-Headers "@CORS_HEADERS@"
      @HIDE_HEADERS@
    }
  }
