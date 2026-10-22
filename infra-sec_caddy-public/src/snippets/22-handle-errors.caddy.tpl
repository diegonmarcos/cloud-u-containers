  handle_errors {
      # Geo-fence refusal (#1102): HTML clients get the explanation page, everyone else plain 403.
      @geo_html {
        expression `{err.message} == "geo-restricted"`
        header Accept *text/html*
      }
      handle @geo_html {
        header Content-Type "text/html; charset=utf-8"
        header Cache-Control "no-store"
        header X-Edge-Geo-Block "1"
        respond `@GEO_PAGE@` 403
      }
      @geo_any expression `{err.message} == "geo-restricted"`
      handle @geo_any {
        header X-Edge-Geo-Block "1"
        respond "Forbidden" 403
      }
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