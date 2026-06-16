  (rate_limiting) {
    rate_limit {
      zone @RL_ZONE@ {
        key    @RL_KEY@
        events @RL_EVENTS@
        window @RL_WINDOW@
      }
    }
  }
