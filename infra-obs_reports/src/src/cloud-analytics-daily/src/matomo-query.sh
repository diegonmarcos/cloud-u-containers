#!/bin/bash
# Emit the last-WINDOW_H hours of Matomo data as labelled pipe-delimited sections.
#
# Read over SSH + `docker exec mysql` for the same reason as umami-query.sh, plus
# one specific to Matomo: no MATOMO_API_TOKEN is provisioned anywhere in the
# fleet (matomo's compose interpolates ${MATOMO_API_TOKEN} but secrets.yaml has
# never carried the key), so the Reporting API is not reachable without minting
# and storing new credential state. The schema needs none.
#
# matomo-hybrid's MariaDB is socket-only (skip-networking — the container is
# host-networked and 3306 belongs to photoprism_mariadb), so `docker exec` is
# also the ONLY way in: there is no TCP listener to connect to.
#
# Apps are told apart from sites by URL scheme: the Android module posts
# url=app://<analytics.app>/<screen>, websites post http(s)://.
set -eu

HOST="${MATOMO_SSH_HOST:-oci-apps}"
WINDOW_H="${WINDOW_H:-24}"

# The container name is DECLARED in infra-obs_matomo/build.json, never invented
# here. infra-obs_matomo is a sibling of infra-obs_reports in every checkout
# this crate runs from (cloud-source/a_solutions/ in the DAG, the repo root
# locally), so one relative hop reaches the declaration and a rename there
# cannot silently desync this reader the way eight copies of a literal would.
# The fallback keeps the tester and any detached checkout working without it.
HERE="$(cd "$(dirname "$0")" && pwd)"
MATOMO_BUILD_JSON="${MATOMO_BUILD_JSON:-$HERE/../../../../../infra-obs_matomo/build.json}"
CONTAINER="${MATOMO_CONTAINER:-$(
  jq -r '.containers.app.container_name // empty' "$MATOMO_BUILD_JSON" 2>/dev/null || true
)}"
CONTAINER="${CONTAINER:-matomo-hybrid}"

ssh -o BatchMode=yes -o ConnectTimeout=15 "$HOST" 'bash -s' <<EOF
set -u
W=${WINDOW_H}
PW=\$(docker exec ${CONTAINER} sh -c 'echo \$MATOMO_DATABASE_PASSWORD' 2>/dev/null || echo '')
q() { docker exec ${CONTAINER} mysql -umatomo -p"\$PW" matomo -N -B -e "\$1" 2>/dev/null | tr '\t' '|' || true; }
CUT="DATE_SUB(NOW(), INTERVAL \$W HOUR)"

# Emitted FIRST and unconditionally. When Matomo's DB is down every metric
# section below is empty, and an empty report reads identically to "a quiet
# day" — which is exactly how this engine sat dead for two days. The backlog
# and the per-process status are the numbers that tell those apart.
echo "##ENGINE"
if q "select 1;" | grep -q 1; then echo "database|reachable"; else echo "database|DOWN — no data can be ingested"; fi
# The container row is emitted UNCONDITIONALLY, exactly as umami-query.sh does
# for umami/umami-db. \`docker exec … supervisorctl\` prints NOTHING when the
# container is absent — stderr is discarded and \`|| true\` swallows the failure
# — so a missing ${CONTAINER} made all seven process rows (mariadb,
# matomo-archiver, matomo-nginx, matomo-php-fpm, receiver-nginx,
# receiver-php-fpm) disappear from the health table instead of one row naming
# the outage. A health table that quietly loses its rows reads like a rendering
# quirk rather than a dead engine, which is the exact failure the ##ENGINE
# contract in build.sh exists to prevent. Observed 2026-09-16: the container
# was absent from oci-apps entirely and the report still showed no engine row.
STATE=\$(docker inspect -f '{{.State.Status}}' ${CONTAINER} 2>/dev/null || echo missing)
echo "${CONTAINER}|\$STATE"
if [ "\$STATE" = running ]; then
  docker exec ${CONTAINER} supervisorctl status 2>/dev/null | awk '{print \$1"|"\$2}' || true
fi

echo "##INBOX"
docker exec ${CONTAINER} sh -c 'ls /inbox 2>/dev/null | wc -l' 2>/dev/null || echo 0

echo "##SUMMARY"
q "select
     (select count(*) from matomo_log_link_visit_action where server_time > \$CUT),
     (select count(distinct idvisitor) from matomo_log_visit where visit_last_action_time > \$CUT),
     (select count(*) from matomo_log_visit where visit_last_action_time > \$CUT);"

echo "##SITES"
q "select substring_index(substring_index(a.name,'://',-1),'/',1) as host,
          count(*) as views,
          count(distinct v.idvisitor) as visitors,
          coalesce(round(avg(v.visit_total_time)),0) as avg_secs
   from matomo_log_link_visit_action lva
   join matomo_log_action a on a.idaction=lva.idaction_url
   join matomo_log_visit  v on v.idvisit=lva.idvisit
   where lva.server_time > \$CUT and a.name not like 'app://%'
   group by 1 order by 2 desc;"

echo "##APPS"
q "select substring_index(substring_index(a.name,'app://',-1),'/',1) as app,
          count(*) as events,
          count(distinct v.idvisitor) as installs,
          sum(a.name like '%app_open%') as opens
   from matomo_log_link_visit_action lva
   join matomo_log_action a on a.idaction=lva.idaction_url
   join matomo_log_visit  v on v.idvisit=lva.idvisit
   where lva.server_time > \$CUT and a.name like 'app://%'
   group by 1 order by 2 desc;"

echo "##PAGES"
q "select a.name, count(*) from matomo_log_link_visit_action lva
   join matomo_log_action a on a.idaction=lva.idaction_url
   where lva.server_time > \$CUT group by 1 order by 2 desc limit 25;"

echo "##COUNTRIES"
q "select coalesce(nullif(location_country,''),'(unknown)'), count(distinct idvisitor)
   from matomo_log_visit where visit_last_action_time > \$CUT group by 1 order by 2 desc limit 15;"

echo "##DEVICES"
q "select concat(coalesce(nullif(config_os,''),'??'),' / ',coalesce(nullif(config_browser_name,''),'??'),' / ',coalesce(nullif(config_device_type,''),'??')),
          count(distinct idvisitor)
   from matomo_log_visit where visit_last_action_time > \$CUT group by 1 order by 2 desc limit 15;"

echo "##REFERRERS"
q "select coalesce(nullif(referer_name,''),'(direct)'), count(*)
   from matomo_log_visit where visit_last_action_time > \$CUT group by 1 order by 2 desc limit 10;"

echo "##HOURLY"
q "select date_format(server_time,'%m-%d %H:00'), count(*)
   from matomo_log_link_visit_action where server_time > \$CUT group by 1 order by 1;"

EOF
