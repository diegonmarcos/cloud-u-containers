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

ssh -o BatchMode=yes -o ConnectTimeout=15 "$HOST" 'bash -s' <<EOF
set -eu
W=${WINDOW_H}
PW=\$(docker exec matomo-hybrid sh -c 'echo \$MATOMO_DATABASE_PASSWORD')
q() { docker exec matomo-hybrid mysql -umatomo -p"\$PW" matomo -N -B -e "\$1" 2>/dev/null | tr '\t' '|'; }
CUT="DATE_SUB(NOW(), INTERVAL \$W HOUR)"

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

echo "##INBOX"
docker exec matomo-hybrid sh -c 'ls /inbox 2>/dev/null | wc -l'
EOF
