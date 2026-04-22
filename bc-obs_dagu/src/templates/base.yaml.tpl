shell: /bin/bash

smtp:
  host: 10.0.0.3
  port: "587"
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
