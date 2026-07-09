        # Empty-body guard: an upstream that answers 200 with Content-Length 0
        # is a FALSE GREEN (blank white page) — treat it as a truthful 502 so
        # handle_errors renders the diagnostic page instead of a silent blank.
        # Gated to GET so legitimately-empty HEAD/OPTIONS responses pass through.
        @empty_ok {
          status 200
          header Content-Length 0
        }
        handle_response @empty_ok {
          @get method GET
          error @get 502
        }
