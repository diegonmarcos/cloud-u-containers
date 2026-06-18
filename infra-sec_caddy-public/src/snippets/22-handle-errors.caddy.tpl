  handle_errors {
      @backend_error expression `@CODES_EXPR@`
      handle @backend_error {
        root * @ERR_ROOT@
        rewrite * /@ERR_FILE@
        file_server
      }
    }