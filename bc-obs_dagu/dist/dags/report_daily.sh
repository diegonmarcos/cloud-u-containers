#!/bin/bash
# ══════════════════════════════════════════════════════════════════════
# C3 Daily Ops Report — Parallelized multi-track collection
# ══════════════════════════════════════════════════════════════════════
SSH="ssh -i /home/dagu/.ssh/vault_id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
DATE=$(date '+%Y-%m-%d')
TIME=$(date '+%H:%M %Z')
CLOUD_DATA="/var/lib/dagu/data/cloud-data"

# ── Cleanup trap ──
TMPDIR_REPORT="/tmp/report_$$"
mkdir -p "$TMPDIR_REPORT"
trap 'rm -rf "$TMPDIR_REPORT"' EXIT

# ── Color constants ──
C_OK="#00d68f"; C_WARN="#ffaa00"; C_CRIT="#ff3d71"; C_DIM="#8899aa"
BG_BODY="#1a1a2e"; BG_CARD="#16213e"; BG_HEAD="#0f3460"; BG_BAR="#2a2a4e"
C_TEXT="#e0e0e0"

# ── Fleet data arrays ──
declare -a VM_NAMES VM_IPS VM_USERS
declare -a VM_UPTIMES VM_LOADS VM_DISKS VM_DISK_PCTS VM_MEMS VM_MEM_PCTS
declare -a VM_CONTAINERS VM_UNHEALTHY VM_EXITED
declare -a VM_SSH_ACCEPTS VM_SSH_FAILS VM_SUDOS VM_TOP_FAILS
declare -a VM_RESTARTS VM_BACKUPS VM_FAILED_UNITS VM_STATUS
declare -a VM_WG_PEERS VM_DOCKER_DFS VM_CONTAINER_STATS
declare -a VM_CTR_RUNNING VM_CTR_TOTAL VM_CTR_UNHEALTHY
declare -a VM_DB_SIZES VM_MAIL_DATA

# ── Helper: parse section between markers from $RAW ──
section() { echo "$RAW" | awk "/===$1===/,/===$2===/" | grep -v '===' || true; }

# ── Helper: color for percentage ──
pct_color() {
  local p=$1
  if [ "$p" -gt 90 ] 2>/dev/null; then echo "$C_CRIT"
  elif [ "$p" -gt 75 ] 2>/dev/null; then echo "$C_WARN"
  else echo "$C_OK"; fi
}

# ── Helper: HTML progress bar ──
progress_bar() {
  local pct=$1 color
  color=$(pct_color "$pct")
  echo "<div style=\"display:inline-block;background:$BG_BAR;border-radius:4px;height:14px;width:80px;vertical-align:middle;\"><div style=\"background:$color;border-radius:4px;height:14px;width:${pct}%;\"></div></div> <span style=\"color:$color;font-size:12px;\">${pct}%</span>"
}

# ── Helper: status badge ──
badge_html() {
  local status=$1 color label
  case "$status" in
    healthy)  color=$C_OK;   label="HEALTHY" ;;
    warning)  color=$C_WARN; label="WARNING" ;;
    critical) color=$C_CRIT; label="CRITICAL" ;;
    *)        color=$C_DIM;  label="UNKNOWN" ;;
  esac
  echo "<span style=\"display:inline-block;padding:2px 8px;border-radius:4px;font-size:11px;font-weight:bold;background:$color;color:$BG_BODY;\">$label</span>"
}

# ══════════════════════════════════════════════════════════════════════
# READ CLOUD-DATA (Track C — instant, no network)
# ══════════════════════════════════════════════════════════════════════
MONITORING_JSON="$CLOUD_DATA/cloud-data-monitoring-targets.json"
DATABASES_JSON="$CLOUD_DATA/cloud-data-databases.json"

# Build VM list from cloud-data
VM_LIST=$(if [ -f "$MONITORING_JSON" ]; then
  jq -r '.vms[] | "\(.ip):\(.name):\(.user)"' "$MONITORING_JSON" | tr '\n' ' '
else
  echo "10.0.0.1:gcp-proxy:diego 10.0.0.3:oci-mail:ubuntu 10.0.0.4:oci-analytics:ubuntu 10.0.0.6:oci-apps:ubuntu"
fi
)

# Parse VM list into arrays first (needed for DB commands)
i=0
for vm_data in $VM_LIST; do
  ip=${vm_data%%:*}
  temp=${vm_data#*:}
  name=${temp%:*}
  user=${temp#*:}
  VM_NAMES[$i]=$name
  VM_IPS[$i]=$ip
  VM_USERS[$i]=$user
  i=$((i+1))
done
VM_COUNT=$i

# ── Build per-VM DB commands from cloud-data ──
declare -a VM_DB_CMDS
for ((j=0; j<VM_COUNT; j++)); do
  VM_DB_CMDS[$j]=""
done

if [ -f "$DATABASES_JSON" ]; then
  db_count=$(jq '.databases | length' "$DATABASES_JSON" 2>/dev/null || echo 0)
  for ((d=0; d<db_count; d++)); do
    db_type=$(jq -r ".databases[$d].type" "$DATABASES_JSON")
    db_container=$(jq -r ".databases[$d].container" "$DATABASES_JSON")
    db_service=$(jq -r ".databases[$d].service" "$DATABASES_JSON")
    db_wg_ip=$(jq -r ".databases[$d].wg_ip" "$DATABASES_JSON")
    db_user=$(jq -r ".databases[$d].user // empty" "$DATABASES_JSON")
    db_name=$(jq -r ".databases[$d].db // empty" "$DATABASES_JSON")
    db_enabled=$(jq -r ".databases[$d].enabled" "$DATABASES_JSON")
    [ "$db_enabled" != "true" ] && continue

    # Find which VM index this belongs to
    for ((j=0; j<VM_COUNT; j++)); do
      if [ "${VM_IPS[$j]}" = "$db_wg_ip" ]; then
        case "$db_type" in
          postgres)
            VM_DB_CMDS[$j]+="echo \"===DB_SIZE_${db_service}===\"
docker exec $db_container psql -U ${db_user:-postgres} -t -c \"SELECT pg_size_pretty(pg_database_size('${db_name:-$db_service}'))\" 2>/dev/null | tr -d ' ' || echo 'N/A'
"
            ;;
          mariadb)
            VM_DB_CMDS[$j]+="echo \"===DB_SIZE_${db_service}===\"
docker exec $db_container mysql -u${db_user:-root} -e \"SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) AS 'MB' FROM information_schema.tables WHERE table_schema='${db_name:-$db_service}'\" -s -N 2>/dev/null | awk '{print \$1 \" MB\"}' || echo 'N/A'
"
            ;;
          sqlite)
            VM_DB_CMDS[$j]+="echo \"===DB_SIZE_${db_service}===\"
docker exec $db_container find / -maxdepth 4 -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' 2>/dev/null | head -3 | xargs ls -lh 2>/dev/null | awk '{print \$5}' | head -1 || echo 'N/A'
"
            ;;
          redis)
            VM_DB_CMDS[$j]+="echo \"===DB_SIZE_${db_service}===\"
docker exec $db_container redis-cli DBSIZE 2>/dev/null | awk '{print \$2 \" keys\"}' || echo 'N/A'
"
            ;;
        esac
        break
      fi
    done
  done
fi

# ══════════════════════════════════════════════════════════════════════
# TRACK A: SSH COLLECTION (parallelized across VMs)
# ══════════════════════════════════════════════════════════════════════
for ((j=0; j<VM_COUNT; j++)); do
  ip=${VM_IPS[$j]}; user=${VM_USERS[$j]}; name=${VM_NAMES[$j]}
  db_cmds="${VM_DB_CMDS[$j]}"

  # Build mail-specific commands for oci-mail
  mail_cmds=""
  if [ "$name" = "oci-mail" ]; then
    mail_cmds='
echo "===MAIL_QUEUE==="
docker exec maddy maddy queue list 2>/dev/null | wc -l || echo "0"
echo "===MAIL_DELIVERED==="
docker logs maddy --since 24h 2>/dev/null | grep -c "delivered" || echo "0"
echo "===MAIL_FAILED==="
docker logs maddy --since 24h 2>/dev/null | grep -c "failed\|bounced" || echo "0"
'
  fi

  (
    RAW_OUT=$($SSH $user@$ip 'bash -s' <<EOSSH 2>/dev/null || echo "===SSH_FAILED===")
echo "===UPTIME==="
uptime -p 2>/dev/null || echo "N/A"
echo "===LOAD==="
cat /proc/loadavg 2>/dev/null | awk '{print \$1, \$2, \$3}' || echo "N/A"
echo "===DISK==="
df -h / 2>/dev/null | awk 'NR==2 {print \$3 "/" \$2 " (" \$5 ")"}' || echo "N/A"
echo "===DISK_PCT==="
df / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",\$5); print \$5}' || echo "0"
echo "===MEM==="
free -h 2>/dev/null | awk '/Mem:/ {print \$3 "/" \$2}' || echo "N/A"
echo "===MEM_PCT==="
free 2>/dev/null | awk '/Mem:/ {printf "%.0f", (\$3/\$2)*100}' || echo "0"
echo "===CONTAINERS==="
docker ps -a --format '{{.Names}}|{{.Status}}|{{.State}}' 2>/dev/null || echo ""
echo "===UNHEALTHY==="
docker ps --filter health=unhealthy --format '{{.Names}}' 2>/dev/null
echo "===EXITED==="
docker ps -a --filter status=exited --format '{{.Names}}' 2>/dev/null | head -10
echo "===CONTAINER_COUNTS==="
R=\$(docker ps -q 2>/dev/null | wc -l)
T=\$(docker ps -aq 2>/dev/null | wc -l)
U=\$(docker ps --filter health=unhealthy -q 2>/dev/null | wc -l)
echo "\$R|\$T|\$U"
echo "===CONTAINER_STATS==="
docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}' 2>/dev/null | sort -t'|' -k2 -rn | head -10 || echo ""
echo "===CONTAINER_FULL==="
docker ps -a --format '{{.Names}}|{{.Image}}|{{.Status}}|{{.RunningFor}}' 2>/dev/null || echo ""
echo "===WG_PEERS==="
sudo wg show wg0 latest-handshakes 2>/dev/null || echo ""
echo "===DOCKER_DF==="
docker system df --format '{{.Type}}|{{.TotalCount}}|{{.Size}}|{{.Reclaimable}}' 2>/dev/null || echo ""
echo "===SSH_ACCEPT==="
journalctl -u ssh --since '24 hours ago' 2>/dev/null | grep -c 'Accepted' || echo 0
echo "===SSH_FAIL==="
journalctl -u ssh --since '24 hours ago' 2>/dev/null | grep -c 'Failed' || echo 0
echo "===SUDO==="
journalctl --since '24 hours ago' 2>/dev/null | grep -c 'sudo:' || echo 0
echo "===TOP_FAIL_IPS==="
journalctl -u ssh --since '24 hours ago' 2>/dev/null | grep 'Failed' | awk '{for(i=1;i<=NF;i++) if(\$i ~ /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/) print \$i}' | sort | uniq -c | sort -rn | head -5 | awk '{print \$2 "|" \$1}'
echo "===RESTARTS==="
journalctl -u docker --since '24 hours ago' 2>/dev/null | grep 'Container.*Started' | awk '{print \$NF}' | sort | uniq -c | sort -rn | head -5 | awk '{print \$2 "|" \$1}'
echo "===BACKUPS==="
find /opt/backups/ -maxdepth 2 -type f -printf '%T@ %s %p\n' 2>/dev/null | sort -rn | head -15 || echo ""
echo "===FAILED_UNITS==="
systemctl --failed --no-legend 2>/dev/null | head -5 | awk '{print \$1}'
$db_cmds
$mail_cmds
echo "===END==="
EOSSH
    echo "$RAW_OUT" > "$TMPDIR_REPORT/vm_$j"
  ) &
done

# ══════════════════════════════════════════════════════════════════════
# TRACK B: API/CURL CALLS (parallel with SSH)
# ══════════════════════════════════════════════════════════════════════

# ── B1: Service endpoint checks ──
if [ -f "$MONITORING_JSON" ]; then
  ep_count=$(jq '.endpoint_checks | length' "$MONITORING_JSON" 2>/dev/null || echo 0)
  for ((e=0; e<ep_count; e++)); do
    ep_service=$(jq -r ".endpoint_checks[$e].service" "$MONITORING_JSON")
    ep_url=$(jq -r ".endpoint_checks[$e].url" "$MONITORING_JSON")
    (
      code=$(curl -s -o /dev/null -w "%{http_code}" -m 5 "$ep_url" 2>/dev/null || echo "000")
      echo "$ep_service|$ep_url|$code"
    ) >> "$TMPDIR_REPORT/ep_$e" &
  done
fi

# ── B2: Certificate expiry checks ──
if [ -f "$MONITORING_JSON" ]; then
  # Deduplicate domains (extract host only, strip paths)
  tls_domains=$(jq -r '.tls_checks[].domain' "$MONITORING_JSON" 2>/dev/null | sed 's|/.*||' | sort -u)
  cert_idx=0
  for domain in $tls_domains; do
    (
      expiry_raw=$(echo | openssl s_client -servername "$domain" -connect "$domain":443 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
      if [ -n "$expiry_raw" ]; then
        expiry_epoch=$(date -d "$expiry_raw" +%s 2>/dev/null || echo 0)
        now_epoch=$(date +%s)
        days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
        echo "$domain|$days_left|$expiry_raw"
      else
        echo "$domain|-1|N/A"
      fi
    ) > "$TMPDIR_REPORT/cert_$cert_idx" &
    cert_idx=$((cert_idx+1))
  done
  CERT_COUNT=$cert_idx
fi

# ── B3: GHA Workflows ──
if [ -n "$GITHUB_TOKEN" ]; then
  (
    curl -s -H "Authorization: Bearer $GITHUB_TOKEN" \
      "https://api.github.com/repos/diegonmarcos/cloud/actions/runs?per_page=10&status=completed" \
      > "$TMPDIR_REPORT/gha_raw" 2>/dev/null
  ) &
fi

# ── B4: GHCR Registry ──
if [ -n "$GITHUB_TOKEN" ]; then
  (
    curl -s -H "Authorization: Bearer $GITHUB_TOKEN" \
      "https://api.github.com/user/packages?package_type=container&per_page=100" \
      > "$TMPDIR_REPORT/ghcr_raw" 2>/dev/null
  ) &
fi

# ── B5: Dagu DAG status ──
(
  curl -s "http://localhost:8070/api/v1/dags" > "$TMPDIR_REPORT/dagu_raw" 2>/dev/null
) &

# ── B6: DNS checks (local dig) ──
(
  echo "MX|$(dig +short MX diegonmarcos.com 2>/dev/null | head -1)" > "$TMPDIR_REPORT/dns"
  echo "SPF|$(dig +short TXT diegonmarcos.com 2>/dev/null | grep 'v=spf1' | head -1)" >> "$TMPDIR_REPORT/dns"
  echo "DKIM|$(dig +short TXT default._domainkey.diegonmarcos.com 2>/dev/null | head -1)" >> "$TMPDIR_REPORT/dns"
  echo "DMARC|$(dig +short TXT _dmarc.diegonmarcos.com 2>/dev/null | head -1)" >> "$TMPDIR_REPORT/dns"
) &

# ══════════════════════════════════════════════════════════════════════
# WAIT FOR ALL PARALLEL JOBS
# ══════════════════════════════════════════════════════════════════════
wait

# ══════════════════════════════════════════════════════════════════════
# PARSE SSH RESULTS
# ══════════════════════════════════════════════════════════════════════
for ((j=0; j<VM_COUNT; j++)); do
  RAW=""
  [ -f "$TMPDIR_REPORT/vm_$j" ] && RAW=$(cat "$TMPDIR_REPORT/vm_$j")

  VM_UPTIMES[$j]=$(section UPTIME LOAD | tr -d '\n' | sed 's/^ *//'); : "${VM_UPTIMES[$j]:=N/A}"
  VM_LOADS[$j]=$(section LOAD DISK | tr -d '\n' | sed 's/^ *//'); : "${VM_LOADS[$j]:=N/A}"
  VM_DISKS[$j]=$(section DISK DISK_PCT | tr -d '\n' | sed 's/^ *//'); : "${VM_DISKS[$j]:=N/A}"
  VM_DISK_PCTS[$j]=$(section DISK_PCT MEM | tr -d '\n' | sed 's/[^0-9]//g'); : "${VM_DISK_PCTS[$j]:=0}"
  VM_MEMS[$j]=$(section MEM MEM_PCT | tr -d '\n' | sed 's/^ *//'); : "${VM_MEMS[$j]:=N/A}"
  VM_MEM_PCTS[$j]=$(section MEM_PCT CONTAINERS | tr -d '\n' | sed 's/[^0-9]//g'); : "${VM_MEM_PCTS[$j]:=0}"
  VM_CONTAINERS[$j]=$(section CONTAINERS UNHEALTHY)
  VM_UNHEALTHY[$j]=$(section UNHEALTHY EXITED)
  VM_EXITED[$j]=$(section EXITED CONTAINER_COUNTS)
  counts=$(section CONTAINER_COUNTS CONTAINER_STATS | head -1)
  VM_CTR_RUNNING[$j]=$(echo "$counts" | cut -d'|' -f1 | tr -d ' '); : "${VM_CTR_RUNNING[$j]:=0}"
  VM_CTR_TOTAL[$j]=$(echo "$counts" | cut -d'|' -f2 | tr -d ' '); : "${VM_CTR_TOTAL[$j]:=0}"
  VM_CTR_UNHEALTHY[$j]=$(echo "$counts" | cut -d'|' -f3 | tr -d ' '); : "${VM_CTR_UNHEALTHY[$j]:=0}"
  VM_CONTAINER_STATS[$j]=$(section CONTAINER_STATS CONTAINER_FULL)
  VM_CONTAINER_FULL[$j]=$(section CONTAINER_FULL WG_PEERS)
  VM_WG_PEERS[$j]=$(section WG_PEERS DOCKER_DF)
  VM_DOCKER_DFS[$j]=$(section DOCKER_DF SSH_ACCEPT)
  VM_SSH_ACCEPTS[$j]=$(section SSH_ACCEPT SSH_FAIL | tr -d '\n' | tr -d ' '); : "${VM_SSH_ACCEPTS[$j]:=0}"
  VM_SSH_FAILS[$j]=$(section SSH_FAIL SUDO | tr -d '\n' | tr -d ' '); : "${VM_SSH_FAILS[$j]:=0}"
  VM_SUDOS[$j]=$(section SUDO TOP_FAIL_IPS | tr -d '\n' | tr -d ' '); : "${VM_SUDOS[$j]:=0}"
  VM_TOP_FAILS[$j]=$(section TOP_FAIL_IPS RESTARTS)
  VM_RESTARTS[$j]=$(section RESTARTS BACKUPS)
  VM_BACKUPS[$j]=$(section BACKUPS FAILED_UNITS)
  VM_FAILED_UNITS[$j]=$(section FAILED_UNITS DB_SIZE_ END)

  # Parse DB sizes — collect all DB_SIZE_* sections
  VM_DB_SIZES[$j]=""
  if [ -f "$DATABASES_JSON" ]; then
    db_services=$(jq -r ".databases[] | select(.wg_ip==\"${VM_IPS[$j]}\") | .service" "$DATABASES_JSON" 2>/dev/null | sort -u)
    for svc in $db_services; do
      size=$(echo "$RAW" | awk "/===DB_SIZE_${svc}===/,/===/" | grep -v '===' | head -1 | tr -d '\n' | sed 's/^ *//')
      : "${size:=N/A}"
      VM_DB_SIZES[$j]+="$svc|$size
"
    done
  fi

  # Parse mail data for oci-mail
  VM_MAIL_DATA[$j]=""
  if [ "${VM_NAMES[$j]}" = "oci-mail" ]; then
    mq=$(echo "$RAW" | awk '/===MAIL_QUEUE===/,/===/' | grep -v '===' | head -1 | tr -d '\n ' || echo "0")
    md=$(echo "$RAW" | awk '/===MAIL_DELIVERED===/,/===/' | grep -v '===' | head -1 | tr -d '\n ' || echo "0")
    mf=$(echo "$RAW" | awk '/===MAIL_FAILED===/,/===/' | grep -v '===' | head -1 | tr -d '\n ' || echo "0")
    VM_MAIL_DATA[$j]="$mq|$md|$mf"
  fi

  # ── Derive health status ──
  dp=${VM_DISK_PCTS[$j]}; mp=${VM_MEM_PCTS[$j]}
  if echo "$RAW" | grep -q '===SSH_FAILED==='; then
    VM_STATUS[$j]="critical"
  elif [ "$dp" -gt 90 ] 2>/dev/null || [ "$mp" -gt 90 ] 2>/dev/null || [ "${VM_CTR_UNHEALTHY[$j]}" -gt 0 ] 2>/dev/null; then
    VM_STATUS[$j]="critical"
  elif [ "$dp" -gt 75 ] 2>/dev/null || [ "$mp" -gt 75 ] 2>/dev/null; then
    VM_STATUS[$j]="warning"
  else
    VM_STATUS[$j]="healthy"
  fi
done

# ── Fleet totals ──
FLEET_RUNNING=0; FLEET_TOTAL=0; FLEET_UNHEALTHY=0
for ((j=0; j<VM_COUNT; j++)); do
  FLEET_RUNNING=$((FLEET_RUNNING + ${VM_CTR_RUNNING[$j]}))
  FLEET_TOTAL=$((FLEET_TOTAL + ${VM_CTR_TOTAL[$j]}))
  FLEET_UNHEALTHY=$((FLEET_UNHEALTHY + ${VM_CTR_UNHEALTHY[$j]}))
done

# ══════════════════════════════════════════════════════════════════════
# BUILD HTML EMAIL
# ══════════════════════════════════════════════════════════════════════
F=$(mktemp)

cat > "$F" <<EOHEADERS
From: no-reply@diegonmarcos.com
To: me@diegonmarcos.com
Subject: C3 Daily Ops Report - $DATE
MIME-Version: 1.0
Content-Type: text/html; charset=UTF-8
EOHEADERS

cat >> "$F" <<'EOSTYLE'

<!DOCTYPE html>
<html><head><meta charset="UTF-8"><style>
body{margin:0;padding:0;background:#1a1a2e}
td,th{font-family:'Courier New',Consolas,monospace}
</style></head>
<body style="margin:0;padding:0;background:#1a1a2e;">
<center>
<table width="100%" cellpadding="0" cellspacing="0" style="background:#1a1a2e;"><tr><td align="center">
<table width="700" cellpadding="0" cellspacing="0" style="max-width:700px;width:100%;">
EOSTYLE

cat >> "$F" <<EOHEAD
<tr><td style="background:#0f3460;padding:20px 24px;text-align:center;border-radius:8px 8px 0 0;">
<h1 style="margin:0;font-size:20px;color:#e0e0e0;font-family:'Courier New',monospace;letter-spacing:1px;">C3 Daily Ops Report</h1>
<p style="margin:4px 0 0;color:#8899aa;font-size:12px;font-family:'Courier New',monospace;">$DATE &mdash; Generated at $TIME</p>
</td></tr>
EOHEAD

# ══════════════════════════════════════════════════════════════════════
# SECTION: Fleet Dashboard
# ══════════════════════════════════════════════════════════════════════
cat >> "$F" <<'EODASH1'
<tr><td style="padding:8px;">
<table width="100%" cellpadding="0" cellspacing="0" style="background:#16213e;border-radius:6px;">
<tr><td colspan="7" style="padding:12px 16px;background:#0f3460;border-radius:6px 6px 0 0;font-size:14px;font-weight:bold;color:#e0e0e0;font-family:'Courier New',monospace;">Fleet Dashboard</td></tr>
<tr>
<th style="text-align:left;color:#8899aa;font-size:11px;padding:8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">VM</th>
<th style="text-align:left;color:#8899aa;font-size:11px;padding:8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Status</th>
<th style="text-align:left;color:#8899aa;font-size:11px;padding:8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Uptime</th>
<th style="text-align:left;color:#8899aa;font-size:11px;padding:8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Load</th>
<th style="text-align:left;color:#8899aa;font-size:11px;padding:8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Mem</th>
<th style="text-align:left;color:#8899aa;font-size:11px;padding:8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Disk</th>
<th style="text-align:left;color:#8899aa;font-size:11px;padding:8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Ctrs</th>
</tr>
EODASH1

for ((j=0; j<VM_COUNT; j++)); do
  n=${VM_NAMES[$j]}; s=${VM_STATUS[$j]}
  badge=$(badge_html "$s")
  up=${VM_UPTIMES[$j]}
  ld=$(echo "${VM_LOADS[$j]}" | awk '{print $1}')
  mp=${VM_MEM_PCTS[$j]}; dp=${VM_DISK_PCTS[$j]}
  mbar=$(progress_bar "$mp"); dbar=$(progress_bar "$dp")
  run=${VM_CTR_RUNNING[$j]}; tot=${VM_CTR_TOTAL[$j]}
  cat >> "$F" <<EOROW
<tr>
<td style="padding:6px 8px;color:#e0e0e0;font-size:12px;font-weight:bold;border-bottom:1px solid rgba(15,52,96,0.5);font-family:'Courier New',monospace;">$n</td>
<td style="padding:6px 8px;border-bottom:1px solid rgba(15,52,96,0.5);">$badge</td>
<td style="padding:6px 8px;color:#8899aa;font-size:11px;border-bottom:1px solid rgba(15,52,96,0.5);font-family:'Courier New',monospace;">$up</td>
<td style="padding:6px 8px;color:#e0e0e0;font-size:12px;border-bottom:1px solid rgba(15,52,96,0.5);font-family:'Courier New',monospace;">$ld</td>
<td style="padding:6px 8px;border-bottom:1px solid rgba(15,52,96,0.5);">$mbar</td>
<td style="padding:6px 8px;border-bottom:1px solid rgba(15,52,96,0.5);">$dbar</td>
<td style="padding:6px 8px;color:#e0e0e0;font-size:12px;border-bottom:1px solid rgba(15,52,96,0.5);font-family:'Courier New',monospace;">$run/$tot</td>
</tr>
EOROW
done

cat >> "$F" <<'EODASH2'
</table></td></tr>
EODASH2

# ══════════════════════════════════════════════════════════════════════
# SECTION: Full Container Inventory
# ══════════════════════════════════════════════════════════════════════
cat >> "$F" <<'EOINV_HEAD'
<tr><td style="padding:8px;">
<table width="100%" cellpadding="0" cellspacing="0" style="background:#16213e;border-radius:6px;">
<tr><td colspan="4" style="padding:12px 16px;background:#0f3460;border-radius:6px 6px 0 0;font-size:14px;font-weight:bold;color:#e0e0e0;font-family:'Courier New',monospace;">Full Container Inventory</td></tr>
EOINV_HEAD

for ((j=0; j<VM_COUNT; j++)); do
  n=${VM_NAMES[$j]}
  full=${VM_CONTAINER_FULL[$j]}
  [ -z "$full" ] && continue

  cat >> "$F" <<EOINV_VM
<tr><td colspan="4" style="padding:8px 8px 2px;color:#e0e0e0;font-size:12px;font-weight:bold;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">$n (${VM_CTR_RUNNING[$j]}/${VM_CTR_TOTAL[$j]} running)</td></tr>
<tr>
<th style="text-align:left;color:#8899aa;font-size:10px;padding:4px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Name</th>
<th style="text-align:left;color:#8899aa;font-size:10px;padding:4px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Image</th>
<th style="text-align:left;color:#8899aa;font-size:10px;padding:4px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Status</th>
<th style="text-align:left;color:#8899aa;font-size:10px;padding:4px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Uptime</th>
</tr>
EOINV_VM

  while IFS='|' read -r cname cimage cstatus cuptime; do
    [ -z "$cname" ] && continue
    # Color based on status keyword
    scolor=$C_OK
    echo "$cstatus" | grep -qi 'exited\|dead\|created' && scolor=$C_CRIT
    echo "$cstatus" | grep -qi 'unhealthy\|restarting' && scolor=$C_WARN
    # Truncate image to last 40 chars
    short_image="$cimage"
    [ ${#cimage} -gt 40 ] && short_image="...${cimage: -37}"
    cat >> "$F" <<EOINV_ROW
<tr>
<td style="padding:2px 8px;color:#e0e0e0;font-size:11px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$cname</td>
<td style="padding:2px 8px;color:$C_DIM;font-size:10px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$short_image</td>
<td style="padding:2px 8px;color:$scolor;font-size:11px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$cstatus</td>
<td style="padding:2px 8px;color:$C_DIM;font-size:11px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$cuptime</td>
</tr>
EOINV_ROW
  done <<< "$full"
done

echo '</table></td></tr>' >> "$F"

# ══════════════════════════════════════════════════════════════════════
# SECTION: Database Report
# ══════════════════════════════════════════════════════════════════════
if [ -f "$DATABASES_JSON" ]; then
  cat >> "$F" <<'EODB_HEAD'
<tr><td style="padding:8px;">
<table width="100%" cellpadding="0" cellspacing="0" style="background:#16213e;border-radius:6px;">
<tr><td colspan="5" style="padding:12px 16px;background:#0f3460;border-radius:6px 6px 0 0;font-size:14px;font-weight:bold;color:#e0e0e0;font-family:'Courier New',monospace;">Database Report</td></tr>
<tr>
<th style="text-align:left;color:#8899aa;font-size:10px;padding:6px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Service</th>
<th style="text-align:left;color:#8899aa;font-size:10px;padding:6px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Type</th>
<th style="text-align:left;color:#8899aa;font-size:10px;padding:6px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Container</th>
<th style="text-align:right;color:#8899aa;font-size:10px;padding:6px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Size</th>
<th style="text-align:left;color:#8899aa;font-size:10px;padding:6px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">VM</th>
</tr>
EODB_HEAD

  db_count=$(jq '.databases | length' "$DATABASES_JSON" 2>/dev/null || echo 0)
  for ((d=0; d<db_count; d++)); do
    db_service=$(jq -r ".databases[$d].service" "$DATABASES_JSON")
    db_type=$(jq -r ".databases[$d].type" "$DATABASES_JSON")
    db_container=$(jq -r ".databases[$d].container" "$DATABASES_JSON")
    db_vm_alias=$(jq -r ".databases[$d].vm_alias" "$DATABASES_JSON")
    db_wg_ip=$(jq -r ".databases[$d].wg_ip" "$DATABASES_JSON")
    db_enabled=$(jq -r ".databases[$d].enabled" "$DATABASES_JSON")

    [ "$db_enabled" != "true" ] && continue

    # Find size from parsed VM data
    db_size="N/A"
    for ((j=0; j<VM_COUNT; j++)); do
      if [ "${VM_IPS[$j]}" = "$db_wg_ip" ]; then
        size_line=$(echo "${VM_DB_SIZES[$j]}" | grep "^${db_service}|" | head -1)
        if [ -n "$size_line" ]; then
          db_size=$(echo "$size_line" | cut -d'|' -f2)
          : "${db_size:=N/A}"
        fi
        break
      fi
    done

    # Type badge color
    type_color=$C_DIM
    case "$db_type" in
      postgres) type_color="#4169E1" ;;
      mariadb)  type_color="#C0765A" ;;
      sqlite)   type_color="#57A6D6" ;;
      redis)    type_color="#DC382D" ;;
    esac

    cat >> "$F" <<EODB_ROW
<tr>
<td style="padding:3px 8px;color:#e0e0e0;font-size:11px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$db_service</td>
<td style="padding:3px 8px;color:$type_color;font-size:11px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$db_type</td>
<td style="padding:3px 8px;color:$C_DIM;font-size:10px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$db_container</td>
<td style="padding:3px 8px;color:#e0e0e0;font-size:11px;text-align:right;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$db_size</td>
<td style="padding:3px 8px;color:$C_DIM;font-size:11px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$db_vm_alias</td>
</tr>
EODB_ROW
  done

  echo '</table></td></tr>' >> "$F"
fi

# ══════════════════════════════════════════════════════════════════════
# SECTION: Backup Status
# ══════════════════════════════════════════════════════════════════════
HAS_BACKUPS=false
for ((j=0; j<VM_COUNT; j++)); do
  [ -n "${VM_BACKUPS[$j]}" ] && HAS_BACKUPS=true
done
if $HAS_BACKUPS; then
  cat >> "$F" <<'EOBK_HEAD'
<tr><td style="padding:8px;">
<table width="100%" cellpadding="0" cellspacing="0" style="background:#16213e;border-radius:6px;">
<tr><td colspan="4" style="padding:12px 16px;background:#0f3460;border-radius:6px 6px 0 0;font-size:14px;font-weight:bold;color:#e0e0e0;font-family:'Courier New',monospace;">Backup Status</td></tr>
<tr>
<th style="text-align:left;color:#8899aa;font-size:10px;padding:6px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">VM</th>
<th style="text-align:left;color:#8899aa;font-size:10px;padding:6px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">File</th>
<th style="text-align:right;color:#8899aa;font-size:10px;padding:6px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Size</th>
<th style="text-align:right;color:#8899aa;font-size:10px;padding:6px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Age</th>
</tr>
EOBK_HEAD

  NOW_EPOCH=$(date +%s)
  for ((j=0; j<VM_COUNT; j++)); do
    n=${VM_NAMES[$j]}; bk=${VM_BACKUPS[$j]}
    [ -z "$bk" ] && continue
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      # Format from find: epoch_timestamp size path
      bk_epoch=$(echo "$line" | awk '{printf "%.0f", $1}')
      bk_size_bytes=$(echo "$line" | awk '{print $2}')
      bk_path=$(echo "$line" | awk '{print $3}')
      bk_file=$(basename "$bk_path" 2>/dev/null || echo "$bk_path")

      # Human-readable size
      if [ "$bk_size_bytes" -gt 1073741824 ] 2>/dev/null; then
        bk_size="$(awk "BEGIN{printf \"%.1f\", $bk_size_bytes/1073741824}")G"
      elif [ "$bk_size_bytes" -gt 1048576 ] 2>/dev/null; then
        bk_size="$(awk "BEGIN{printf \"%.1f\", $bk_size_bytes/1048576}")M"
      elif [ "$bk_size_bytes" -gt 1024 ] 2>/dev/null; then
        bk_size="$(awk "BEGIN{printf \"%.0f\", $bk_size_bytes/1024}")K"
      else
        bk_size="${bk_size_bytes}B"
      fi

      # Age in hours
      if [ "$bk_epoch" -gt 0 ] 2>/dev/null; then
        age_hours=$(( (NOW_EPOCH - bk_epoch) / 3600 ))
        if [ $age_hours -lt 24 ]; then
          age_color=$C_OK; age_str="${age_hours}h ago"
        elif [ $age_hours -lt 72 ]; then
          age_color=$C_WARN; age_str="$((age_hours/24))d ${age_hours}h"
        else
          age_color=$C_CRIT; age_str="$((age_hours/24))d"
        fi
      else
        age_color=$C_DIM; age_str="unknown"
      fi

      cat >> "$F" <<EOBK_ROW
<tr>
<td style="padding:2px 8px;color:#e0e0e0;font-size:11px;font-weight:bold;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$n</td>
<td style="padding:2px 8px;color:#e0e0e0;font-size:11px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$bk_file</td>
<td style="padding:2px 8px;color:$C_DIM;font-size:11px;text-align:right;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$bk_size</td>
<td style="padding:2px 8px;color:$age_color;font-size:11px;text-align:right;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$age_str</td>
</tr>
EOBK_ROW
    done <<< "$bk"
  done

  echo '</table></td></tr>' >> "$F"
fi

# ══════════════════════════════════════════════════════════════════════
# SECTION: Service Endpoints
# ══════════════════════════════════════════════════════════════════════
if [ -f "$MONITORING_JSON" ]; then
  ep_count=$(jq '.endpoint_checks | length' "$MONITORING_JSON" 2>/dev/null || echo 0)
  if [ "$ep_count" -gt 0 ]; then
    cat >> "$F" <<'EOEP_HEAD'
<tr><td style="padding:8px;">
<table width="100%" cellpadding="0" cellspacing="0" style="background:#16213e;border-radius:6px;">
<tr><td colspan="3" style="padding:12px 16px;background:#0f3460;border-radius:6px 6px 0 0;font-size:14px;font-weight:bold;color:#e0e0e0;font-family:'Courier New',monospace;">Service Endpoints</td></tr>
<tr>
<th style="text-align:left;color:#8899aa;font-size:10px;padding:6px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Service</th>
<th style="text-align:left;color:#8899aa;font-size:10px;padding:6px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">URL</th>
<th style="text-align:center;color:#8899aa;font-size:10px;padding:6px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Status</th>
</tr>
EOEP_HEAD

    for ((e=0; e<ep_count; e++)); do
      if [ -f "$TMPDIR_REPORT/ep_$e" ]; then
        ep_line=$(cat "$TMPDIR_REPORT/ep_$e" | head -1)
        ep_svc=$(echo "$ep_line" | cut -d'|' -f1)
        ep_url=$(echo "$ep_line" | cut -d'|' -f2)
        ep_code=$(echo "$ep_line" | cut -d'|' -f3)
      else
        ep_svc=$(jq -r ".endpoint_checks[$e].service" "$MONITORING_JSON")
        ep_url=$(jq -r ".endpoint_checks[$e].url" "$MONITORING_JSON")
        ep_code="N/A"
      fi

      # Color code
      ep_color=$C_CRIT
      case "$ep_code" in
        2[0-9][0-9]|3[0-9][0-9]) ep_color=$C_OK ;;
        4[0-9][0-9]) ep_color=$C_WARN ;;
      esac

      cat >> "$F" <<EOEP_ROW
<tr>
<td style="padding:3px 8px;color:#e0e0e0;font-size:11px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$ep_svc</td>
<td style="padding:3px 8px;color:$C_DIM;font-size:10px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$ep_url</td>
<td style="padding:3px 8px;text-align:center;border-bottom:1px solid rgba(15,52,96,0.3);"><span style="display:inline-block;padding:2px 8px;border-radius:4px;font-size:11px;font-weight:bold;background:$ep_color;color:$BG_BODY;font-family:'Courier New',monospace;">$ep_code</span></td>
</tr>
EOEP_ROW
    done

    echo '</table></td></tr>' >> "$F"
  fi
fi

# ══════════════════════════════════════════════════════════════════════
# SECTION: Certificate Expiry
# ══════════════════════════════════════════════════════════════════════
if [ "${CERT_COUNT:-0}" -gt 0 ]; then
  cat >> "$F" <<'EOCERT_HEAD'
<tr><td style="padding:8px;">
<table width="100%" cellpadding="0" cellspacing="0" style="background:#16213e;border-radius:6px;">
<tr><td colspan="3" style="padding:12px 16px;background:#0f3460;border-radius:6px 6px 0 0;font-size:14px;font-weight:bold;color:#e0e0e0;font-family:'Courier New',monospace;">Certificate Expiry</td></tr>
<tr>
<th style="text-align:left;color:#8899aa;font-size:10px;padding:6px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Domain</th>
<th style="text-align:right;color:#8899aa;font-size:10px;padding:6px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Days Left</th>
<th style="text-align:left;color:#8899aa;font-size:10px;padding:6px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Expires</th>
</tr>
EOCERT_HEAD

  for ((c=0; c<CERT_COUNT; c++)); do
    if [ -f "$TMPDIR_REPORT/cert_$c" ]; then
      cert_line=$(cat "$TMPDIR_REPORT/cert_$c" | head -1)
      cert_domain=$(echo "$cert_line" | cut -d'|' -f1)
      cert_days=$(echo "$cert_line" | cut -d'|' -f2)
      cert_expiry=$(echo "$cert_line" | cut -d'|' -f3)

      cert_color=$C_OK
      if [ "$cert_days" -lt 0 ] 2>/dev/null; then
        cert_color=$C_CRIT
      elif [ "$cert_days" -lt 7 ] 2>/dev/null; then
        cert_color=$C_CRIT
      elif [ "$cert_days" -lt 30 ] 2>/dev/null; then
        cert_color=$C_WARN
      fi

      cat >> "$F" <<EOCERT_ROW
<tr>
<td style="padding:3px 8px;color:#e0e0e0;font-size:11px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$cert_domain</td>
<td style="padding:3px 8px;color:$cert_color;font-size:11px;text-align:right;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">${cert_days}d</td>
<td style="padding:3px 8px;color:$C_DIM;font-size:11px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$cert_expiry</td>
</tr>
EOCERT_ROW
    fi
  done

  echo '</table></td></tr>' >> "$F"
fi

# ══════════════════════════════════════════════════════════════════════
# SECTION: DNS Status
# ══════════════════════════════════════════════════════════════════════
if [ -f "$TMPDIR_REPORT/dns" ]; then
  cat >> "$F" <<'EODNS_HEAD'
<tr><td style="padding:8px;">
<table width="100%" cellpadding="0" cellspacing="0" style="background:#16213e;border-radius:6px;">
<tr><td colspan="3" style="padding:12px 16px;background:#0f3460;border-radius:6px 6px 0 0;font-size:14px;font-weight:bold;color:#e0e0e0;font-family:'Courier New',monospace;">DNS Status (diegonmarcos.com)</td></tr>
<tr>
<th style="text-align:left;color:#8899aa;font-size:10px;padding:6px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Record</th>
<th style="text-align:center;color:#8899aa;font-size:10px;padding:6px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Status</th>
<th style="text-align:left;color:#8899aa;font-size:10px;padding:6px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Value</th>
</tr>
EODNS_HEAD

  while IFS='|' read -r rec_type rec_value; do
    [ -z "$rec_type" ] && continue
    if [ -n "$rec_value" ] && [ "$rec_value" != "" ]; then
      dns_status="PASS"
      dns_color=$C_OK
    else
      dns_status="FAIL"
      dns_color=$C_CRIT
      rec_value="not found"
    fi
    # Truncate long values
    short_val="$rec_value"
    [ ${#rec_value} -gt 60 ] && short_val="${rec_value:0:57}..."
    cat >> "$F" <<EODNS_ROW
<tr>
<td style="padding:3px 8px;color:#e0e0e0;font-size:11px;font-weight:bold;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$rec_type</td>
<td style="padding:3px 8px;text-align:center;border-bottom:1px solid rgba(15,52,96,0.3);"><span style="display:inline-block;padding:2px 8px;border-radius:4px;font-size:11px;font-weight:bold;background:$dns_color;color:$BG_BODY;font-family:'Courier New',monospace;">$dns_status</span></td>
<td style="padding:3px 8px;color:$C_DIM;font-size:10px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$short_val</td>
</tr>
EODNS_ROW
  done < "$TMPDIR_REPORT/dns"

  echo '</table></td></tr>' >> "$F"
fi

# ══════════════════════════════════════════════════════════════════════
# SECTION: Mail Queue & Stats
# ══════════════════════════════════════════════════════════════════════
HAS_MAIL=false
for ((j=0; j<VM_COUNT; j++)); do
  [ -n "${VM_MAIL_DATA[$j]}" ] && HAS_MAIL=true
done
if $HAS_MAIL; then
  cat >> "$F" <<'EOMAIL_HEAD'
<tr><td style="padding:8px;">
<table width="100%" cellpadding="0" cellspacing="0" style="background:#16213e;border-radius:6px;">
<tr><td colspan="2" style="padding:12px 16px;background:#0f3460;border-radius:6px 6px 0 0;font-size:14px;font-weight:bold;color:#e0e0e0;font-family:'Courier New',monospace;">Mail Queue &amp; Stats (24h)</td></tr>
EOMAIL_HEAD

  for ((j=0; j<VM_COUNT; j++)); do
    mdata=${VM_MAIL_DATA[$j]}
    [ -z "$mdata" ] && continue
    mq=$(echo "$mdata" | cut -d'|' -f1); : "${mq:=0}"
    md=$(echo "$mdata" | cut -d'|' -f2); : "${md:=0}"
    mf=$(echo "$mdata" | cut -d'|' -f3); : "${mf:=0}"

    mq_color=$C_OK; [ "$mq" -gt 5 ] 2>/dev/null && mq_color=$C_WARN; [ "$mq" -gt 20 ] 2>/dev/null && mq_color=$C_CRIT
    mf_color=$C_OK; [ "$mf" -gt 0 ] 2>/dev/null && mf_color=$C_WARN; [ "$mf" -gt 5 ] 2>/dev/null && mf_color=$C_CRIT

    cat >> "$F" <<EOMAIL_ROW
<tr>
<td style="padding:4px 8px;color:$C_DIM;font-size:12px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">Queued</td>
<td style="padding:4px 8px;color:$mq_color;font-size:12px;font-weight:bold;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$mq</td>
</tr>
<tr>
<td style="padding:4px 8px;color:$C_DIM;font-size:12px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">Delivered (24h)</td>
<td style="padding:4px 8px;color:$C_OK;font-size:12px;font-weight:bold;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$md</td>
</tr>
<tr>
<td style="padding:4px 8px;color:$C_DIM;font-size:12px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">Failed (24h)</td>
<td style="padding:4px 8px;color:$mf_color;font-size:12px;font-weight:bold;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$mf</td>
</tr>
EOMAIL_ROW
  done

  echo '</table></td></tr>' >> "$F"
fi

# ══════════════════════════════════════════════════════════════════════
# SECTION: GHA Workflows
# ══════════════════════════════════════════════════════════════════════
if [ -f "$TMPDIR_REPORT/gha_raw" ] && jq -e '.workflow_runs' "$TMPDIR_REPORT/gha_raw" >/dev/null 2>&1; then
  gha_count=$(jq '.workflow_runs | length' "$TMPDIR_REPORT/gha_raw" 2>/dev/null || echo 0)
  if [ "$gha_count" -gt 0 ]; then
    cat >> "$F" <<'EOGHA_HEAD'
<tr><td style="padding:8px;">
<table width="100%" cellpadding="0" cellspacing="0" style="background:#16213e;border-radius:6px;">
<tr><td colspan="3" style="padding:12px 16px;background:#0f3460;border-radius:6px 6px 0 0;font-size:14px;font-weight:bold;color:#e0e0e0;font-family:'Courier New',monospace;">GHA Workflows (Last 10)</td></tr>
<tr>
<th style="text-align:left;color:#8899aa;font-size:10px;padding:6px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Workflow</th>
<th style="text-align:center;color:#8899aa;font-size:10px;padding:6px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Status</th>
<th style="text-align:left;color:#8899aa;font-size:10px;padding:6px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Time</th>
</tr>
EOGHA_HEAD

    for ((g=0; g<gha_count && g<10; g++)); do
      gha_name=$(jq -r ".workflow_runs[$g].name" "$TMPDIR_REPORT/gha_raw")
      gha_conclusion=$(jq -r ".workflow_runs[$g].conclusion" "$TMPDIR_REPORT/gha_raw")
      gha_time=$(jq -r ".workflow_runs[$g].created_at" "$TMPDIR_REPORT/gha_raw" | sed 's/T/ /;s/Z//')

      gha_color=$C_DIM; gha_label="$gha_conclusion"
      case "$gha_conclusion" in
        success)  gha_color=$C_OK; gha_label="SUCCESS" ;;
        failure)  gha_color=$C_CRIT; gha_label="FAILED" ;;
        cancelled) gha_color=$C_WARN; gha_label="CANCEL" ;;
      esac

      cat >> "$F" <<EOGHA_ROW
<tr>
<td style="padding:3px 8px;color:#e0e0e0;font-size:11px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$gha_name</td>
<td style="padding:3px 8px;text-align:center;border-bottom:1px solid rgba(15,52,96,0.3);"><span style="display:inline-block;padding:2px 8px;border-radius:4px;font-size:11px;font-weight:bold;background:$gha_color;color:$BG_BODY;font-family:'Courier New',monospace;">$gha_label</span></td>
<td style="padding:3px 8px;color:$C_DIM;font-size:10px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$gha_time</td>
</tr>
EOGHA_ROW
    done

    echo '</table></td></tr>' >> "$F"
  fi
fi

# ══════════════════════════════════════════════════════════════════════
# SECTION: GHCR Registry
# ══════════════════════════════════════════════════════════════════════
if [ -f "$TMPDIR_REPORT/ghcr_raw" ] && jq -e '.[0]' "$TMPDIR_REPORT/ghcr_raw" >/dev/null 2>&1; then
  ghcr_total=$(jq 'length' "$TMPDIR_REPORT/ghcr_raw" 2>/dev/null || echo 0)
  if [ "$ghcr_total" -gt 0 ]; then
    cat >> "$F" <<EOGHCR_HEAD
<tr><td style="padding:8px;">
<table width="100%" cellpadding="0" cellspacing="0" style="background:#16213e;border-radius:6px;">
<tr><td colspan="2" style="padding:12px 16px;background:#0f3460;border-radius:6px 6px 0 0;font-size:14px;font-weight:bold;color:#e0e0e0;font-family:'Courier New',monospace;">GHCR Registry ($ghcr_total packages)</td></tr>
<tr>
<th style="text-align:left;color:#8899aa;font-size:10px;padding:6px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Package</th>
<th style="text-align:left;color:#8899aa;font-size:10px;padding:6px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Updated</th>
</tr>
EOGHCR_HEAD

    # Sort by updated_at descending, show last 10
    ghcr_sorted=$(jq -r '[.[] | {name: .name, updated: .updated_at}] | sort_by(.updated) | reverse | .[0:10] | .[] | "\(.name)|\(.updated)"' "$TMPDIR_REPORT/ghcr_raw" 2>/dev/null)
    while IFS='|' read -r pkg_name pkg_updated; do
      [ -z "$pkg_name" ] && continue
      pkg_time=$(echo "$pkg_updated" | sed 's/T/ /;s/Z//')
      cat >> "$F" <<EOGHCR_ROW
<tr>
<td style="padding:2px 8px;color:#e0e0e0;font-size:11px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$pkg_name</td>
<td style="padding:2px 8px;color:$C_DIM;font-size:10px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$pkg_time</td>
</tr>
EOGHCR_ROW
    done <<< "$ghcr_sorted"

    echo '</table></td></tr>' >> "$F"
  fi
fi

# ══════════════════════════════════════════════════════════════════════
# SECTION: Dagu DAG Status
# ══════════════════════════════════════════════════════════════════════
if [ -f "$TMPDIR_REPORT/dagu_raw" ] && jq -e '.DAGs' "$TMPDIR_REPORT/dagu_raw" >/dev/null 2>&1; then
  dag_count=$(jq '.DAGs | length' "$TMPDIR_REPORT/dagu_raw" 2>/dev/null || echo 0)
  if [ "$dag_count" -gt 0 ]; then
    cat >> "$F" <<'EODAG_HEAD'
<tr><td style="padding:8px;">
<table width="100%" cellpadding="0" cellspacing="0" style="background:#16213e;border-radius:6px;">
<tr><td colspan="3" style="padding:12px 16px;background:#0f3460;border-radius:6px 6px 0 0;font-size:14px;font-weight:bold;color:#e0e0e0;font-family:'Courier New',monospace;">Dagu DAG Status</td></tr>
<tr>
<th style="text-align:left;color:#8899aa;font-size:10px;padding:6px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">DAG</th>
<th style="text-align:center;color:#8899aa;font-size:10px;padding:6px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Status</th>
<th style="text-align:left;color:#8899aa;font-size:10px;padding:6px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Last Run</th>
</tr>
EODAG_HEAD

    jq -r '.DAGs[] | "\(.DAG.Name // .File // "unknown")|\(.Status.Status // "none")|\(.Status.StartedAt // "never")"' "$TMPDIR_REPORT/dagu_raw" 2>/dev/null | while IFS='|' read -r dag_name dag_status dag_time; do
      [ -z "$dag_name" ] && continue
      dag_color=$C_DIM; dag_label="$dag_status"
      case "$dag_status" in
        0|success|finished) dag_color=$C_OK; dag_label="OK" ;;
        1|failed|error)     dag_color=$C_CRIT; dag_label="FAIL" ;;
        2|running)          dag_color=$C_WARN; dag_label="RUN" ;;
        none)               dag_color=$C_DIM; dag_label="NEVER" ;;
      esac
      dag_time_fmt=$(echo "$dag_time" | sed 's/T/ /;s/Z//;s/\.[0-9]*//')
      cat >> "$F" <<EODAG_ROW
<tr>
<td style="padding:2px 8px;color:#e0e0e0;font-size:11px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$dag_name</td>
<td style="padding:2px 8px;text-align:center;border-bottom:1px solid rgba(15,52,96,0.3);"><span style="display:inline-block;padding:2px 8px;border-radius:4px;font-size:11px;font-weight:bold;background:$dag_color;color:$BG_BODY;font-family:'Courier New',monospace;">$dag_label</span></td>
<td style="padding:2px 8px;color:$C_DIM;font-size:10px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$dag_time_fmt</td>
</tr>
EODAG_ROW
    done

    echo '</table></td></tr>' >> "$F"
  fi
fi

# ══════════════════════════════════════════════════════════════════════
# SECTION: Container Details per VM (existing — top CPU/mem)
# ══════════════════════════════════════════════════════════════════════
for ((j=0; j<VM_COUNT; j++)); do
  n=${VM_NAMES[$j]}
  containers=${VM_CONTAINERS[$j]}
  unhealthy=${VM_UNHEALTHY[$j]}
  exited=${VM_EXITED[$j]}
  stats=${VM_CONTAINER_STATS[$j]}

  cat >> "$F" <<EOCTR_HEAD
<tr><td style="padding:8px;">
<table width="100%" cellpadding="0" cellspacing="0" style="background:#16213e;border-radius:6px;">
<tr><td colspan="4" style="padding:12px 16px;background:#0f3460;border-radius:6px 6px 0 0;font-size:14px;font-weight:bold;color:#e0e0e0;font-family:'Courier New',monospace;">Container Resources — $n</td></tr>
EOCTR_HEAD

  if [ -n "$unhealthy" ]; then
    while IFS= read -r c; do
      [ -z "$c" ] && continue
      cat >> "$F" <<EOCTR_U
<tr><td colspan="4" style="padding:4px 8px;color:$C_CRIT;font-size:12px;font-family:'Courier New',monospace;">UNHEALTHY: $c</td></tr>
EOCTR_U
    done <<< "$unhealthy"
  fi

  if [ -n "$exited" ]; then
    while IFS= read -r c; do
      [ -z "$c" ] && continue
      cat >> "$F" <<EOCTR_E
<tr><td colspan="4" style="padding:4px 8px;color:$C_WARN;font-size:12px;font-family:'Courier New',monospace;">EXITED: $c</td></tr>
EOCTR_E
    done <<< "$exited"
  fi

  # Top containers by CPU/mem
  if [ -n "$stats" ]; then
    cat >> "$F" <<'EOCTR_STAT_H'
<tr>
<th style="text-align:left;color:#8899aa;font-size:10px;padding:6px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Container</th>
<th style="text-align:right;color:#8899aa;font-size:10px;padding:6px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">CPU</th>
<th style="text-align:right;color:#8899aa;font-size:10px;padding:6px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Mem Usage</th>
<th style="text-align:right;color:#8899aa;font-size:10px;padding:6px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Mem %</th>
</tr>
EOCTR_STAT_H
    while IFS='|' read -r cname ccpu cmem cmemp; do
      [ -z "$cname" ] && continue
      cat >> "$F" <<EOCTR_STAT_R
<tr>
<td style="padding:3px 8px;color:#e0e0e0;font-size:11px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$cname</td>
<td style="padding:3px 8px;color:#e0e0e0;font-size:11px;text-align:right;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$ccpu</td>
<td style="padding:3px 8px;color:#e0e0e0;font-size:11px;text-align:right;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$cmem</td>
<td style="padding:3px 8px;color:#e0e0e0;font-size:11px;text-align:right;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$cmemp</td>
</tr>
EOCTR_STAT_R
    done <<< "$stats"
  fi

  echo '</table></td></tr>' >> "$F"
done

# ══════════════════════════════════════════════════════════════════════
# SECTION: Security Events (24h)
# ══════════════════════════════════════════════════════════════════════
cat >> "$F" <<'EOSEC_HEAD'
<tr><td style="padding:8px;">
<table width="100%" cellpadding="0" cellspacing="0" style="background:#16213e;border-radius:6px;">
<tr><td colspan="4" style="padding:12px 16px;background:#0f3460;border-radius:6px 6px 0 0;font-size:14px;font-weight:bold;color:#e0e0e0;font-family:'Courier New',monospace;">Security Events (24h)</td></tr>
<tr>
<th style="text-align:left;color:#8899aa;font-size:11px;padding:8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">VM</th>
<th style="text-align:right;color:#8899aa;font-size:11px;padding:8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">SSH OK</th>
<th style="text-align:right;color:#8899aa;font-size:11px;padding:8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">SSH Fail</th>
<th style="text-align:right;color:#8899aa;font-size:11px;padding:8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">sudo</th>
</tr>
EOSEC_HEAD

for ((j=0; j<VM_COUNT; j++)); do
  n=${VM_NAMES[$j]}
  sa=${VM_SSH_ACCEPTS[$j]}; sf=${VM_SSH_FAILS[$j]}; su=${VM_SUDOS[$j]}
  sf_color=$C_OK; [ "$sf" -gt 10 ] 2>/dev/null && sf_color=$C_WARN; [ "$sf" -gt 50 ] 2>/dev/null && sf_color=$C_CRIT
  cat >> "$F" <<EOSEC_ROW
<tr>
<td style="padding:4px 8px;color:#e0e0e0;font-size:12px;font-weight:bold;border-bottom:1px solid rgba(15,52,96,0.5);font-family:'Courier New',monospace;">$n</td>
<td style="padding:4px 8px;color:$C_OK;font-size:12px;text-align:right;border-bottom:1px solid rgba(15,52,96,0.5);font-family:'Courier New',monospace;">$sa</td>
<td style="padding:4px 8px;color:$sf_color;font-size:12px;text-align:right;border-bottom:1px solid rgba(15,52,96,0.5);font-family:'Courier New',monospace;">$sf</td>
<td style="padding:4px 8px;color:#e0e0e0;font-size:12px;text-align:right;border-bottom:1px solid rgba(15,52,96,0.5);font-family:'Courier New',monospace;">$su</td>
</tr>
EOSEC_ROW
done

# Top failed IPs across all VMs
HAS_FAILS=false
for ((j=0; j<VM_COUNT; j++)); do
  [ -n "${VM_TOP_FAILS[$j]}" ] && HAS_FAILS=true
done
if $HAS_FAILS; then
  cat >> "$F" <<'EOFAIL_H'
<tr><td colspan="4" style="padding:8px 8px 4px;color:#8899aa;font-size:11px;font-family:'Courier New',monospace;">Top failed IPs:</td></tr>
EOFAIL_H
  for ((j=0; j<VM_COUNT; j++)); do
    n=${VM_NAMES[$j]}; fails=${VM_TOP_FAILS[$j]}
    [ -z "$fails" ] && continue
    while IFS='|' read -r fip fcount; do
      [ -z "$fip" ] && continue
      cat >> "$F" <<EOFAIL_R
<tr><td colspan="4" style="padding:2px 16px;color:$C_WARN;font-size:11px;font-family:'Courier New',monospace;">$n: $fip ($fcount attempts)</td></tr>
EOFAIL_R
    done <<< "$fails"
  done
fi

echo '</table></td></tr>' >> "$F"

# ══════════════════════════════════════════════════════════════════════
# SECTION: Docker Disk Usage
# ══════════════════════════════════════════════════════════════════════
cat >> "$F" <<'EODF_HEAD'
<tr><td style="padding:8px;">
<table width="100%" cellpadding="0" cellspacing="0" style="background:#16213e;border-radius:6px;">
<tr><td colspan="4" style="padding:12px 16px;background:#0f3460;border-radius:6px 6px 0 0;font-size:14px;font-weight:bold;color:#e0e0e0;font-family:'Courier New',monospace;">Docker Disk Usage</td></tr>
EODF_HEAD

for ((j=0; j<VM_COUNT; j++)); do
  n=${VM_NAMES[$j]}; ddf=${VM_DOCKER_DFS[$j]}
  [ -z "$ddf" ] && continue
  cat >> "$F" <<EODF_VM
<tr><td colspan="4" style="padding:6px 8px;color:#e0e0e0;font-size:12px;font-weight:bold;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">$n</td></tr>
EODF_VM
  while IFS='|' read -r dtype dcount dsize dreclaimable; do
    [ -z "$dtype" ] && continue
    cat >> "$F" <<EODF_ROW
<tr>
<td style="padding:2px 16px;color:#8899aa;font-size:11px;font-family:'Courier New',monospace;">$dtype</td>
<td style="padding:2px 8px;color:#e0e0e0;font-size:11px;text-align:right;font-family:'Courier New',monospace;">$dcount</td>
<td style="padding:2px 8px;color:#e0e0e0;font-size:11px;text-align:right;font-family:'Courier New',monospace;">$dsize</td>
<td style="padding:2px 8px;color:$C_DIM;font-size:11px;text-align:right;font-family:'Courier New',monospace;">reclaimable: $dreclaimable</td>
</tr>
EODF_ROW
  done <<< "$ddf"
done

echo '</table></td></tr>' >> "$F"

# ══════════════════════════════════════════════════════════════════════
# SECTION: WireGuard Peers
# ══════════════════════════════════════════════════════════════════════
HAS_WG=false
for ((j=0; j<VM_COUNT; j++)); do
  [ -n "${VM_WG_PEERS[$j]}" ] && HAS_WG=true
done
if $HAS_WG; then
  cat >> "$F" <<'EOWG_HEAD'
<tr><td style="padding:8px;">
<table width="100%" cellpadding="0" cellspacing="0" style="background:#16213e;border-radius:6px;">
<tr><td colspan="3" style="padding:12px 16px;background:#0f3460;border-radius:6px 6px 0 0;font-size:14px;font-weight:bold;color:#e0e0e0;font-family:'Courier New',monospace;">WireGuard Peers</td></tr>
EOWG_HEAD
  for ((j=0; j<VM_COUNT; j++)); do
    n=${VM_NAMES[$j]}; wg=${VM_WG_PEERS[$j]}
    [ -z "$wg" ] && continue
    cat >> "$F" <<EOWG_VM
<tr><td colspan="3" style="padding:6px 8px;color:#e0e0e0;font-size:12px;font-weight:bold;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">$n</td></tr>
EOWG_VM
    while read -r peer ts; do
      [ -z "$peer" ] && continue
      age="never"
      if [ "$ts" -gt 0 ] 2>/dev/null; then
        diff=$(( $(date +%s) - ts ))
        if [ $diff -lt 120 ]; then age="${diff}s ago"
        elif [ $diff -lt 7200 ]; then age="$((diff/60))m ago"
        else age="$((diff/3600))h ago"; fi
      fi
      short_peer="${peer:0:8}..."
      color=$C_OK; [ "$ts" = "0" ] && color=$C_CRIT
      [ "$diff" -gt 300 ] 2>/dev/null && color=$C_WARN
      cat >> "$F" <<EOWG_ROW
<tr>
<td style="padding:2px 16px;color:$C_DIM;font-size:11px;font-family:'Courier New',monospace;">$short_peer</td>
<td style="padding:2px 8px;color:$color;font-size:11px;font-family:'Courier New',monospace;">$age</td>
</tr>
EOWG_ROW
    done <<< "$wg"
  done
  echo '</table></td></tr>' >> "$F"
fi

# ══════════════════════════════════════════════════════════════════════
# SECTION: Failed Systemd Units
# ══════════════════════════════════════════════════════════════════════
HAS_FAILED=false
for ((j=0; j<VM_COUNT; j++)); do
  [ -n "${VM_FAILED_UNITS[$j]}" ] && HAS_FAILED=true
done
if $HAS_FAILED; then
  cat >> "$F" <<'EOFU_HEAD'
<tr><td style="padding:8px;">
<table width="100%" cellpadding="0" cellspacing="0" style="background:#16213e;border-radius:6px;">
<tr><td colspan="2" style="padding:12px 16px;background:#0f3460;border-radius:6px 6px 0 0;font-size:14px;font-weight:bold;color:#e0e0e0;font-family:'Courier New',monospace;">Failed Systemd Units</td></tr>
EOFU_HEAD
  for ((j=0; j<VM_COUNT; j++)); do
    n=${VM_NAMES[$j]}; fu=${VM_FAILED_UNITS[$j]}
    [ -z "$fu" ] && continue
    while IFS= read -r unit; do
      [ -z "$unit" ] && continue
      cat >> "$F" <<EOFU_ROW
<tr>
<td style="padding:3px 8px;color:#e0e0e0;font-size:12px;font-weight:bold;font-family:'Courier New',monospace;">$n</td>
<td style="padding:3px 8px;color:$C_CRIT;font-size:12px;font-family:'Courier New',monospace;">$unit</td>
</tr>
EOFU_ROW
    done <<< "$fu"
  done
  echo '</table></td></tr>' >> "$F"
fi

# ══════════════════════════════════════════════════════════════════════
# SECTION: Container Restarts (24h)
# ══════════════════════════════════════════════════════════════════════
HAS_RESTARTS=false
for ((j=0; j<VM_COUNT; j++)); do
  [ -n "${VM_RESTARTS[$j]}" ] && HAS_RESTARTS=true
done
if $HAS_RESTARTS; then
  cat >> "$F" <<'EORS_HEAD'
<tr><td style="padding:8px;">
<table width="100%" cellpadding="0" cellspacing="0" style="background:#16213e;border-radius:6px;">
<tr><td colspan="3" style="padding:12px 16px;background:#0f3460;border-radius:6px 6px 0 0;font-size:14px;font-weight:bold;color:#e0e0e0;font-family:'Courier New',monospace;">Container Restarts (24h)</td></tr>
EORS_HEAD
  for ((j=0; j<VM_COUNT; j++)); do
    n=${VM_NAMES[$j]}; rs=${VM_RESTARTS[$j]}
    [ -z "$rs" ] && continue
    while IFS='|' read -r rname rcount; do
      [ -z "$rname" ] && continue
      rc_color=$C_OK; [ "$rcount" -gt 3 ] 2>/dev/null && rc_color=$C_WARN; [ "$rcount" -gt 10 ] 2>/dev/null && rc_color=$C_CRIT
      cat >> "$F" <<EORS_ROW
<tr>
<td style="padding:2px 8px;color:#e0e0e0;font-size:12px;font-weight:bold;font-family:'Courier New',monospace;">$n</td>
<td style="padding:2px 8px;color:#e0e0e0;font-size:11px;font-family:'Courier New',monospace;">$rname</td>
<td style="padding:2px 8px;color:$rc_color;font-size:11px;text-align:right;font-family:'Courier New',monospace;">$rcount</td>
</tr>
EORS_ROW
    done <<< "$rs"
  done
  echo '</table></td></tr>' >> "$F"
fi

# ══════════════════════════════════════════════════════════════════════
# FOOTER
# ══════════════════════════════════════════════════════════════════════
cat >> "$F" <<EOFOOT
<tr><td style="text-align:center;padding:16px;color:#8899aa;font-size:11px;font-family:'Courier New',monospace;">
C3 Daily Ops Report &mdash; $DATE $TIME<br>
<a href="http://10.0.0.3:8070" style="color:#00d68f;">Dagu Dashboard</a>
</td></tr>
</table>
</td></tr></table>
</center>
</body>
</html>
EOFOOT

# ══════════════════════════════════════════════════════════════════════
# SEND EMAIL via Maddy SMTP :587
# ══════════════════════════════════════════════════════════════════════
curl -s --url "smtp://10.0.0.3:587" \
  --ssl-reqd -k \
  --user "no-reply@diegonmarcos.com:${NOREPLY_PASSWORD}" \
  --mail-from "no-reply@diegonmarcos.com" \
  --mail-rcpt "me@diegonmarcos.com" \
  -T "$F"
SEND_RC=$?
rm -f "$F"
if [ $SEND_RC -eq 0 ]; then
  echo "C3 Daily Ops Report sent for $DATE via Maddy SMTP :587"
else
  echo "FAILED to send report (curl exit $SEND_RC)"
  exit 1
fi
