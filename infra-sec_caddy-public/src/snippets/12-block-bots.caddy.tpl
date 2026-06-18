  (block_bots) {
    @bad_bots header_regexp User-Agent "(?i)(@BOT_UAS@)"
    respond @bad_bots 403
  }
