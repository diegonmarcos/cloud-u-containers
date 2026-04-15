#!/bin/bash
SSH="ssh -i /home/dagu/.ssh/vault_id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
DATE=$(date '+%Y-%m-%d')
TIME=$(date '+%H:%M %Z')

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
# COLLECT DATA FROM EACH VM
# ══════════════════════════════════════════════════════════════════════
VM_LIST=$(if [ -f "/var/lib/dagu/data/cloud-data/cloud-data-monitoring-targets.json" ]; then
  jq -r '.vms[] | "\(.ip):\(.name):\(.user)"' "/var/lib/dagu/data/cloud-data/cloud-data-monitoring-targets.json" | tr '\n' ' '
else
  echo "10.0.0.1:gcp-proxy:diego 10.0.0.3:oci-mail:ubuntu 10.0.0.4:oci-analytics:ubuntu 10.0.0.6:oci-apps:ubuntu"
fi
)
i=0
for vm_data in $VM_LIST; do
  ip=${vm_data%%:*}
  temp=${vm_data#*:}
  name=${temp%:*}
  user=${temp#*:}
  VM_NAMES[$i]=$name
  VM_IPS[$i]=$ip
  VM_USERS[$i]=$user

  RAW=$($SSH $user@$ip 'bash -s' <<'EOSSH' 2>/dev/null || echo "===SSH_FAILED==="
echo "===UPTIME==="
uptime -p 2>/dev/null || echo "N/A"
echo "===LOAD==="
cat /proc/loadavg 2>/dev/null | awk '{print $1, $2, $3}' || echo "N/A"
echo "===DISK==="
df -h / 2>/dev/null | awk 'NR==2 {print $3 "/" $2 " (" $5 ")"}' || echo "N/A"
echo "===DISK_PCT==="
df / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}' || echo "0"
echo "===MEM==="
free -h 2>/dev/null | awk '/Mem:/ {print $3 "/" $2}' || echo "N/A"
echo "===MEM_PCT==="
free 2>/dev/null | awk '/Mem:/ {printf "%.0f", ($3/$2)*100}' || echo "0"
echo "===CONTAINERS==="
docker ps -a --format '{{.Names}}|{{.Status}}|{{.State}}' 2>/dev/null | head -40 || echo ""
echo "===UNHEALTHY==="
docker ps --filter health=unhealthy --format '{{.Names}}' 2>/dev/null
echo "===EXITED==="
docker ps -a --filter status=exited --format '{{.Names}}' 2>/dev/null | head -10
echo "===CONTAINER_COUNTS==="
R=$(docker ps -q 2>/dev/null | wc -l)
T=$(docker ps -aq 2>/dev/null | wc -l)
U=$(docker ps --filter health=unhealthy -q 2>/dev/null | wc -l)
echo "$R|$T|$U"
echo "===CONTAINER_STATS==="
docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}' 2>/dev/null | sort -t'|' -k2 -rn | head -10 || echo ""
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
journalctl -u ssh --since '24 hours ago' 2>/dev/null | grep 'Failed' | awk '{for(i=1;i<=NF;i++) if($i ~ /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/) print $i}' | sort | uniq -c | sort -rn | head -5 | awk '{print $2 "|" $1}'
echo "===RESTARTS==="
journalctl -u docker --since '24 hours ago' 2>/dev/null | grep 'Container.*Started' | awk '{print $NF}' | sort | uniq -c | sort -rn | head -5 | awk '{print $2 "|" $1}'
echo "===BACKUPS==="
ls -lht /opt/backups/ 2>/dev/null | awk 'NR>1{print $NF "|" $5 "|" $6 " " $7 " " $8}' || echo ""
echo "===FAILED_UNITS==="
systemctl --failed --no-legend 2>/dev/null | head -5 | awk '{print $1}'
echo "===END==="
EOSSH
)

  # ── Parse sections into arrays ──
  VM_UPTIMES[$i]=$(section UPTIME LOAD | tr -d '\n' | sed 's/^ *//'); : "${VM_UPTIMES[$i]:=N/A}"
  VM_LOADS[$i]=$(section LOAD DISK | tr -d '\n' | sed 's/^ *//'); : "${VM_LOADS[$i]:=N/A}"
  VM_DISKS[$i]=$(section DISK DISK_PCT | tr -d '\n' | sed 's/^ *//'); : "${VM_DISKS[$i]:=N/A}"
  VM_DISK_PCTS[$i]=$(section DISK_PCT MEM | tr -d '\n' | sed 's/[^0-9]//g'); : "${VM_DISK_PCTS[$i]:=0}"
  VM_MEMS[$i]=$(section MEM MEM_PCT | tr -d '\n' | sed 's/^ *//'); : "${VM_MEMS[$i]:=N/A}"
  VM_MEM_PCTS[$i]=$(section MEM_PCT CONTAINERS | tr -d '\n' | sed 's/[^0-9]//g'); : "${VM_MEM_PCTS[$i]:=0}"
  VM_CONTAINERS[$i]=$(section CONTAINERS UNHEALTHY)
  VM_UNHEALTHY[$i]=$(section UNHEALTHY EXITED)
  VM_EXITED[$i]=$(section EXITED CONTAINER_COUNTS)
  counts=$(section CONTAINER_COUNTS CONTAINER_STATS | head -1)
  VM_CTR_RUNNING[$i]=$(echo "$counts" | cut -d'|' -f1 | tr -d ' '); : "${VM_CTR_RUNNING[$i]:=0}"
  VM_CTR_TOTAL[$i]=$(echo "$counts" | cut -d'|' -f2 | tr -d ' '); : "${VM_CTR_TOTAL[$i]:=0}"
  VM_CTR_UNHEALTHY[$i]=$(echo "$counts" | cut -d'|' -f3 | tr -d ' '); : "${VM_CTR_UNHEALTHY[$i]:=0}"
  VM_CONTAINER_STATS[$i]=$(section CONTAINER_STATS WG_PEERS)
  VM_WG_PEERS[$i]=$(section WG_PEERS DOCKER_DF)
  VM_DOCKER_DFS[$i]=$(section DOCKER_DF SSH_ACCEPT)
  VM_SSH_ACCEPTS[$i]=$(section SSH_ACCEPT SSH_FAIL | tr -d '\n' | tr -d ' '); : "${VM_SSH_ACCEPTS[$i]:=0}"
  VM_SSH_FAILS[$i]=$(section SSH_FAIL SUDO | tr -d '\n' | tr -d ' '); : "${VM_SSH_FAILS[$i]:=0}"
  VM_SUDOS[$i]=$(section SUDO TOP_FAIL_IPS | tr -d '\n' | tr -d ' '); : "${VM_SUDOS[$i]:=0}"
  VM_TOP_FAILS[$i]=$(section TOP_FAIL_IPS RESTARTS)
  VM_RESTARTS[$i]=$(section RESTARTS BACKUPS)
  VM_BACKUPS[$i]=$(section BACKUPS FAILED_UNITS)
  VM_FAILED_UNITS[$i]=$(section FAILED_UNITS END)

  # ── Derive health status ──
  dp=${VM_DISK_PCTS[$i]}; mp=${VM_MEM_PCTS[$i]}
  if echo "$RAW" | grep -q '===SSH_FAILED==='; then
    VM_STATUS[$i]="critical"
  elif [ "$dp" -gt 90 ] 2>/dev/null || [ "$mp" -gt 90 ] 2>/dev/null || [ "${VM_CTR_UNHEALTHY[$i]}" -gt 0 ] 2>/dev/null; then
    VM_STATUS[$i]="critical"
  elif [ "$dp" -gt 75 ] 2>/dev/null || [ "$mp" -gt 75 ] 2>/dev/null; then
    VM_STATUS[$i]="warning"
  else
    VM_STATUS[$i]="healthy"
  fi
  i=$((i+1))
done
VM_COUNT=$i

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

# ── Fleet Dashboard ──
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

# ── Container Details per VM ──
for ((j=0; j<VM_COUNT; j++)); do
  n=${VM_NAMES[$j]}
  containers=${VM_CONTAINERS[$j]}
  unhealthy=${VM_UNHEALTHY[$j]}
  exited=${VM_EXITED[$j]}
  stats=${VM_CONTAINER_STATS[$j]}

  cat >> "$F" <<EOCTR_HEAD
<tr><td style="padding:8px;">
<table width="100%" cellpadding="0" cellspacing="0" style="background:#16213e;border-radius:6px;">
<tr><td colspan="4" style="padding:12px 16px;background:#0f3460;border-radius:6px 6px 0 0;font-size:14px;font-weight:bold;color:#e0e0e0;font-family:'Courier New',monospace;">Containers — $n</td></tr>
EOCTR_HEAD

  if [ -n "$unhealthy" ]; then
    while IFS= read -r c; do
      [ -z "$c" ] && continue
      cat >> "$F" <<EOCTR_U
<tr><td colspan="4" style="padding:4px 8px;color:$C_CRIT;font-size:12px;font-family:'Courier New',monospace;">⚠ UNHEALTHY: $c</td></tr>
EOCTR_U
    done <<< "$unhealthy"
  fi

  if [ -n "$exited" ]; then
    while IFS= read -r c; do
      [ -z "$c" ] && continue
      cat >> "$F" <<EOCTR_E
<tr><td colspan="4" style="padding:4px 8px;color:$C_WARN;font-size:12px;font-family:'Courier New',monospace;">✗ EXITED: $c</td></tr>
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

# ── Security Events ──
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

# ── Docker Disk Usage ──
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

# ── WireGuard Peers ──
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

# ── Failed Systemd Units ──
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

# ── Container Restarts (24h) ──
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

# ── FOOTER ──
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

# ── Send email via Maddy SMTP :587 (external route, authenticated) ──
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
