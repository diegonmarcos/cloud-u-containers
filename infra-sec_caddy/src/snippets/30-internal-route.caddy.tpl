  @SERVICE@ {
    # No explicit bind: `bind 10.0.0.1` used to put this site on its OWN
    # Caddy server (srv1, listen=[10.0.0.1:8443]), separate from the public
    # routes' server (srv0, listen=[0.0.0.0:8443]). caddy-l4
    # (00-globals.caddy.tpl) owns :443 and forwards non-mail TLS to
    # 127.0.0.1:8443 — a loopback address srv1 never bound — so the entire
    # .app/.db internal zone was unreachable fleet-wide (confirmed via
    # admin API: srv1 held valid, never-hit routes for snappymail.app/
    # gitea.app). :8443 is not publicly exposed (firewall allows only
    # 443/51820/25) and WG-mesh membership is the real trust boundary, so
    # merging into the same default listener as the public routes loses no
    # isolation while fixing reachability. 2026-07-09.
    tls internal
    reverse_proxy @UPSTREAM@ {
@EMPTY_GUARD@
    }
@HANDLE_ERRORS@
  }
