  handle_errors {
      @backend_error expression `@CODES_EXPR@`
      handle @backend_error {
        # Truthful fallback. A backend error (upstream down/unreachable) must NOT
        # masquerade as 200 — a plain `file_server` serves the error page with 200,
        # a FALSE GREEN that hid genuinely-down services behind the edge
        # (openobserve/news-gdelt/c3-infra-api, 2026-06-23: public probe saw 200
        # wormhole while the service was absent). Serve the page but PRESERVE the
        # real upstream status, and tag the response so probes detect the fallback
        # deterministically instead of guessing from the body.
        header X-Edge-Fallback "1"
        header X-Edge-Upstream-Status "{err.status_code}"
        root * @ERR_ROOT@
        rewrite * /@ERR_FILE@
        file_server {
          status {err.status_code}
        }
      }
    }