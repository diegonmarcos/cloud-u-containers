  @SERVICE@ {
    # Bind must byte-match public routes: see 30-internal-route.caddy.tpl.
    # 2026-07-09.
@PUBLIC_BIND_LINE@
@MESH_GUARD@
    tls {
      on_demand
      issuer internal {
        ca mesh
      }
    }
    reverse_proxy @UPSTREAM@ {
@EMPTY_GUARD@
    }
@HANDLE_ERRORS@
  }
