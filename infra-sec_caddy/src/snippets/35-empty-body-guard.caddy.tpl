        # Empty-body guard: an upstream that answers 200 with Content-Length 0
        # is a FALSE GREEN (blank white page) — treat it as a truthful 502 so
        # handle_errors renders the diagnostic page instead of a silent blank.
        # Gated to GET so legitimately-empty HEAD/OPTIONS responses pass through.
        #
        # CRITICAL: once ANY named handle_response matcher exists on a
        # reverse_proxy, Caddy defers writing the response entirely — a
        # response that matches NO handle_response block writes NOTHING
        # (not "pass through unmodified"). Confirmed via production incident
        # 2026-07-09: this guard alone silently emptied every real response
        # (gitea.app 14821b -> 0b, snappymail.app 161138b -> 0b) fleet-wide,
        # a worse outage than the bug it fixed. The bare fallback block below
        # is MANDATORY and MUST come after @empty_ok — it copies through every
        # response that isn't the empty-200 false-green.
        @empty_ok {
          status 200
          header Content-Length 0
        }
        handle_response @empty_ok {
          @get method GET
          error @get 502
        }
        handle_response {
          copy_response
        }
