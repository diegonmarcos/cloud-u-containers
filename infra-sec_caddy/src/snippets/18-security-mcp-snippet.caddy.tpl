  # Same posture as (security) minus the shared global rate-limit zone: a
  # Claude session start initializes ~10 MCP servers in parallel (several
  # POSTs each, plus SSE reconnects), which drains 100/min instantly and the
  # client's own retries then keep the bucket empty -- servers "fail to
  # connect" in a slow drip. MCP gets its own bucket so a session start can
  # never starve the browser-facing sites, and vice versa.
  (security_mcp) {
    import security_headers
    import block_bots
    import block_scanners
    import rate_limiting_mcp
    import ip_block
    import access_log
  }
