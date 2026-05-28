shell: /bin/bash

smtp:
  host: 10.0.0.3
  # Maddy on oci-mail disables port 587 (Mailu→Maddy migration left
  # only :465 implicit-TLS active per the dovecot proxy.conf). Dagu's
  # mail_on.failure / .success notifications were dialing :587 and
  # getting ECONNREFUSED, so failure emails never reached me@. Use 465
  # (Dagu honours implicit TLS when the port is 465 — no `tls: true`
  # needed).
  port: "465"
  username: "no-reply@diegonmarcos.com"
  password: "$NOREPLY_PASSWORD"

mail_on:
  failure: false
  success: false

error_mail:
  from: no-reply@diegonmarcos.com
  to:
    - me@diegonmarcos.com
  prefix: "[Dagu FAIL]"
  attach_logs: true

info_mail:
  from: no-reply@diegonmarcos.com
  to:
    - me@diegonmarcos.com
  prefix: "[Dagu OK]"
