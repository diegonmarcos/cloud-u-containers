  handle_errors {
      @backend_error expression `@CODES_EXPR@`
      handle @backend_error {
        # Truthful fallback (parity with infra-sec_caddy-public, 2026-06-23): a
        # backend error (upstream down/unreachable) must NOT masquerade as 200. A
        # plain `file_server` serves the error page with 200, a FALSE GREEN that
        # hides genuinely-down services behind the edge. Serve the page but
        # PRESERVE the real upstream status and tag it for probes.
        header X-Edge-Fallback "1"
        header X-Edge-Upstream-Status "{err.status_code}"
        root * @ERR_ROOT@
        rewrite * /@ERR_FILE@
        file_server {
          status {err.status_code}
        }
      }
    }