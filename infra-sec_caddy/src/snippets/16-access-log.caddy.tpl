  (access_log) {
    log {
      output file @LOG_PATH@ {
        roll_size @LOG_ROLL_SIZE@
        roll_keep @LOG_ROLL_KEEP@
      }
      format @LOG_FORMAT@
    }
  }
