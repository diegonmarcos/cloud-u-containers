#!/bin/bash
# Emit the last-WINDOW_H hours of Umami data as labelled pipe-delimited sections.
#
# Read over SSH + `docker exec psql` rather than the Umami HTTP API on purpose:
# the API needs a username/password round-trip per run and its /api/websites
# stats endpoints reshape between Umami majors, while the schema below is
# stable and needs no credential beyond the SSH key the reports runner already
# mounts. Every other engine in this crate is read the same way.
#
# A "site" is a hostname containing a dot (a real domain); anything else is an
# APP — the Android analytics module reports hostname=<build.json analytics.app>
# (e.g. ac_cloud-nav), which is a bare identifier by construction.
set -eu

HOST="${UMAMI_SSH_HOST:-oci-analytics}"
WINDOW_H="${WINDOW_H:-24}"
DB="docker exec umami-db psql -U umami -d umami -t -A -F'|' -c"

remote() { ssh -o BatchMode=yes -o ConnectTimeout=15 "$HOST" 'bash -s'; }

remote <<EOF
W="${WINDOW_H} hours"

# Same rationale as matomo-query.sh: emitted first and unconditionally so a
# dead collector is never indistinguishable from a quiet day.
echo "##ENGINE"
if $DB "select 1;" 2>/dev/null | grep -q 1; then echo "database|reachable"; else echo "database|DOWN — no data can be ingested"; fi
for c in umami umami-db; do
  echo "\$c|\$(docker inspect -f '{{.State.Status}}{{if .State.Health}} ({{.State.Health.Status}}){{end}}' \$c 2>/dev/null || echo missing)"
done

echo "##SUMMARY"
$DB "select count(*) filter (where event_type=1),
            count(distinct session_id),
            count(distinct e.hostname)
     from website_event e where created_at > now() - interval '\$W';"

echo "##SITES"
$DB "select e.hostname,
            count(*) filter (where e.event_type=1) as views,
            count(distinct e.session_id)           as visitors,
            round(extract(epoch from (max(e.created_at)-min(e.created_at)))
                  / greatest(count(distinct e.session_id),1))::int as avg_secs
     from website_event e
     where e.created_at > now() - interval '\$W' and e.hostname like '%.%'
     group by 1 order by 2 desc;"

echo "##APPS"
$DB "select e.hostname,
            count(*)                     as events,
            count(distinct e.session_id) as installs,
            count(*) filter (where e.url_path like '%app_open%') as opens
     from website_event e
     where e.created_at > now() - interval '\$W' and e.hostname not like '%.%'
     group by 1 order by 2 desc;"

echo "##PAGES"
$DB "select e.hostname||e.url_path, count(*)
     from website_event e
     where e.created_at > now() - interval '\$W' and e.event_type=1
     group by 1 order by 2 desc limit 25;"

echo "##COUNTRIES"
$DB "select coalesce(nullif(s.country,''),'(unknown)'), count(distinct e.session_id)
     from website_event e join session s on s.session_id=e.session_id
     where e.created_at > now() - interval '\$W'
     group by 1 order by 2 desc limit 15;"

echo "##DEVICES"
$DB "select coalesce(nullif(s.os,''),'(unknown)')||' / '||coalesce(nullif(s.browser,''),'(unknown)')||' / '||coalesce(nullif(s.device,''),'(unknown)'),
            count(distinct e.session_id)
     from website_event e join session s on s.session_id=e.session_id
     where e.created_at > now() - interval '\$W'
     group by 1 order by 2 desc limit 15;"

echo "##REFERRERS"
$DB "select coalesce(nullif(e.referrer_domain,''),'(direct)'), count(*)
     from website_event e
     where e.created_at > now() - interval '\$W'
     group by 1 order by 2 desc limit 10;"

echo "##HOURLY"
$DB "select to_char(date_trunc('hour', e.created_at),'MM-DD HH24:00'), count(*)
     from website_event e
     where e.created_at > now() - interval '\$W'
     group by 1 order by 1;"
EOF
