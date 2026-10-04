# CrowdSec acquisition — DORMANT placeholder. INTENTIONALLY EMPTY.
#
# With no data sources declared here, the CrowdSec engine acquires and parses
# NO logs: it detects nothing and (with no bouncer wired) remediates nothing.
# The container stays up and healthy purely as a Cloudflare-off fallback.
#
# To ACTIVATE later, add one source block per log stream, e.g. Caddy access
# logs shipped from the edge:
#
#   filenames:
#     - /var/log/caddy/access.log
#   labels:
#     type: caddy
#
# then install the matching collection (cscli collections install crowdsecurity/caddy)
# and wire a bouncer. Until then, this file must remain source-empty.
