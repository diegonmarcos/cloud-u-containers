  (rate_limiting) {
    # Static assets are exempt from the per-IP `@RL_ZONE@` zone: one page load
    # (linktree: ~80 icons/images in parallel + SW precache) must never trip it.
    # They get their own, much higher per-IP zone so a flood is still bounded.
    rate_limit {
      zone @RL_STATIC_ZONE@ {
        match {
          path_regexp `@RL_STATIC_RE@`
        }
        key    @RL_KEY@
        events @RL_STATIC_EVENTS@
        window @RL_STATIC_WINDOW@
      }
      zone @RL_ZONE@ {
        match {
          not path_regexp `@RL_STATIC_RE@`
        }
        key    @RL_KEY@
        events @RL_EVENTS@
        window @RL_WINDOW@
      }
    }
  }
