  # client_ip == the connection address here (no trusted proxies; the PROXY-protocol hop from
  # layer4 carries the real client address), and is the same address the country matcher uses.
  # (geo_fence) -- ticket #1102, declared in _shared/geo-fence.json. Mesh/loopback sources
  # bypass; any other client whose country is not allowed (or unknown) is turned into an
  # error that the site's handle_errors answers with 403. `order error first` (globals)
  # makes this run BEFORE forward_auth, so a denied client never reaches Authelia.
  (geo_fence) {
    @geo_denied {
      not client_ip @GEO_EXEMPT@
      not maxmind_geolocation {
        db_path @GEO_DB@
        allow_countries @GEO_ALLOW@
      }
    }
    error @geo_denied "geo-restricted" 403
  }
