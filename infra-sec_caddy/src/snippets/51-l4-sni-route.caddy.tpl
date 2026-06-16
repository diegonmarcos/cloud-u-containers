          # @COMMENT@ (SNI: @SNI@)
          @SNI_MATCHER@ tls sni @SNI@
          route @SNI_MATCHER@ {
            proxy {
              upstream @UPSTREAM@@PP_LINE@
            }
          }