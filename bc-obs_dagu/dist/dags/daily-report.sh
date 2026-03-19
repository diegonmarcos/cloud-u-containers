#!/bin/bash
SSH="ssh -i /root/.ssh/vault_id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
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
i=0
for vm_data in 10.0.0.1:gcp-proxy:diego 10.0.0.3:oci-mail:ubuntu 10.0.0.4:oci-analytics:ubuntu 10.0.0.6:oci-apps:ubuntu; do
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

# ── Email headers ──
cat > "$F" <<EOHEADERS
From: no-reply@diegonmarcos.com
To: me@diegonmarcos.com
Subject: C3 Daily Ops Report - $DATE
MIME-Version: 1.0
Content-Type: text/html; charset=UTF-8
EOHEADERS

# ── HTML start + styles ──
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

# ── HEADER BANNER ──
cat >> "$F" <<EOHEAD
<tr><td style="background:#0f3460;padding:20px 24px;text-align:center;border-radius:8px 8px 0 0;">
<h1 style="margin:0;font-size:20px;color:#e0e0e0;font-family:'Courier New',monospace;letter-spacing:1px;">C3 Daily Ops Report</h1>
<p style="margin:4px 0 0;color:#8899aa;font-size:12px;font-family:'Courier New',monospace;">$DATE &mdash; Generated at $TIME</p>
</td></tr>
EOHEAD

# ══════════════════════════════════════════════════════════════════════
# FLEET DASHBOARD
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
</table>
</td></tr>
EODASH2

# ══════════════════════════════════════════════════════════════════════
# 1. OPERATIONS — Fleet Health
# ══════════════════════════════════════════════════════════════════════
cat >> "$F" <<'EOOPS1'
<tr><td style="padding:8px;">
<table width="100%" cellpadding="0" cellspacing="0" style="background:#16213e;border-radius:6px;">
<tr><td style="padding:12px 16px;background:#0f3460;border-radius:6px 6px 0 0;font-size:14px;font-weight:bold;color:#e0e0e0;font-family:'Courier New',monospace;">1. Operations &mdash; Fleet Health</td></tr>
<tr><td style="padding:12px 16px;">
EOOPS1

for ((j=0; j<VM_COUNT; j++)); do
  n=${VM_NAMES[$j]}; up=${VM_UPTIMES[$j]}; ld=${VM_LOADS[$j]}
  dk=${VM_DISKS[$j]}; dp=${VM_DISK_PCTS[$j]}
  mm=${VM_MEMS[$j]}; mp=${VM_MEM_PCTS[$j]}
  mbar=$(progress_bar "$mp"); dbar=$(progress_bar "$dp")
  cat >> "$F" <<EOOPSVM
<table width="100%" cellpadding="0" cellspacing="0" style="margin-bottom:12px;">
<tr><td colspan="2" style="padding:4px 8px;font-weight:bold;color:#e0e0e0;font-size:13px;font-family:'Courier New',monospace;">$n</td></tr>
<tr><td style="padding:3px 8px;color:#8899aa;width:80px;font-size:12px;font-family:'Courier New',monospace;">Uptime</td><td style="padding:3px 8px;color:#e0e0e0;font-size:12px;font-family:'Courier New',monospace;">$up</td></tr>
<tr><td style="padding:3px 8px;color:#8899aa;font-size:12px;font-family:'Courier New',monospace;">Load</td><td style="padding:3px 8px;color:#e0e0e0;font-size:12px;font-family:'Courier New',monospace;">$ld</td></tr>
<tr><td style="padding:3px 8px;color:#8899aa;font-size:12px;font-family:'Courier New',monospace;">Disk</td><td style="padding:3px 8px;color:#e0e0e0;font-size:12px;font-family:'Courier New',monospace;">$dk &nbsp; $dbar</td></tr>
<tr><td style="padding:3px 8px;color:#8899aa;font-size:12px;font-family:'Courier New',monospace;">Memory</td><td style="padding:3px 8px;color:#e0e0e0;font-size:12px;font-family:'Courier New',monospace;">$mm &nbsp; $mbar</td></tr>
</table>
EOOPSVM
done

# WireGuard Mesh
cat >> "$F" <<'EOWG1'
<table width="100%" cellpadding="0" cellspacing="0" style="margin-top:8px;">
<tr><td colspan="3" style="padding:6px 8px;font-weight:bold;color:#e0e0e0;font-size:13px;font-family:'Courier New',monospace;">WireGuard Mesh</td></tr>
<tr>
<th style="text-align:left;color:#8899aa;font-size:11px;padding:4px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">VM</th>
<th style="text-align:left;color:#8899aa;font-size:11px;padding:4px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Peer</th>
<th style="text-align:left;color:#8899aa;font-size:11px;padding:4px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Last Handshake</th>
</tr>
EOWG1

NOW_EPOCH=$(date +%s)
for ((j=0; j<VM_COUNT; j++)); do
  n=${VM_NAMES[$j]}; peers=${VM_WG_PEERS[$j]}
  if [ -n "$peers" ]; then
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      peer_key=$(echo "$line" | awk '{print substr($1,1,8) "..."}')
      epoch=$(echo "$line" | awk '{print $2}')
      if [ "$epoch" -gt 0 ] 2>/dev/null; then
        age=$((NOW_EPOCH - epoch))
        if [ "$age" -lt 180 ]; then age_str="${age}s ago"; age_color=$C_OK
        elif [ "$age" -lt 600 ]; then age_str="$((age/60))m ago"; age_color=$C_WARN
        else age_str="$((age/60))m ago"; age_color=$C_CRIT; fi
      else
        age_str="never"; age_color=$C_CRIT
      fi
      cat >> "$F" <<EOWGROW
<tr>
<td style="padding:4px 8px;color:#e0e0e0;font-size:12px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$n</td>
<td style="padding:4px 8px;color:#8899aa;font-size:12px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:monospace;">$peer_key</td>
<td style="padding:4px 8px;color:$age_color;font-size:12px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$age_str</td>
</tr>
EOWGROW
    done <<< "$peers"
  fi
done

cat >> "$F" <<'EOWG2'
</table>
</td></tr></table>
</td></tr>
EOWG2

# ══════════════════════════════════════════════════════════════════════
# 2. INVENTORY — Container Census
# ══════════════════════════════════════════════════════════════════════
cat >> "$F" <<'EOINV1'
<tr><td style="padding:8px;">
<table width="100%" cellpadding="0" cellspacing="0" style="background:#16213e;border-radius:6px;">
<tr><td style="padding:12px 16px;background:#0f3460;border-radius:6px 6px 0 0;font-size:14px;font-weight:bold;color:#e0e0e0;font-family:'Courier New',monospace;">2. Inventory &mdash; Container Census</td></tr>
<tr><td style="padding:12px 16px;">
<table width="100%" cellpadding="0" cellspacing="0">
<tr>
<th style="text-align:left;color:#8899aa;font-size:11px;padding:6px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">VM</th>
<th style="text-align:left;color:#8899aa;font-size:11px;padding:6px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Running</th>
<th style="text-align:left;color:#8899aa;font-size:11px;padding:6px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Stopped</th>
<th style="text-align:left;color:#8899aa;font-size:11px;padding:6px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Unhealthy</th>
<th style="text-align:left;color:#8899aa;font-size:11px;padding:6px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Total</th>
</tr>
EOINV1

for ((j=0; j<VM_COUNT; j++)); do
  n=${VM_NAMES[$j]}; run=${VM_CTR_RUNNING[$j]}
  tot=${VM_CTR_TOTAL[$j]}; unh=${VM_CTR_UNHEALTHY[$j]}
  stopped=$((tot - run))
  if [ "$unh" -gt 0 ] 2>/dev/null; then unh_color=$C_CRIT; else unh_color=$C_TEXT; fi
  cat >> "$F" <<EOINVROW
<tr>
<td style="padding:6px 8px;color:#e0e0e0;font-size:12px;border-bottom:1px solid rgba(15,52,96,0.5);font-weight:bold;font-family:'Courier New',monospace;">$n</td>
<td style="padding:6px 8px;color:$C_OK;font-size:12px;border-bottom:1px solid rgba(15,52,96,0.5);font-family:'Courier New',monospace;">$run</td>
<td style="padding:6px 8px;color:#8899aa;font-size:12px;border-bottom:1px solid rgba(15,52,96,0.5);font-family:'Courier New',monospace;">$stopped</td>
<td style="padding:6px 8px;color:$unh_color;font-size:12px;border-bottom:1px solid rgba(15,52,96,0.5);font-family:'Courier New',monospace;">$unh</td>
<td style="padding:6px 8px;color:#e0e0e0;font-size:12px;border-bottom:1px solid rgba(15,52,96,0.5);font-family:'Courier New',monospace;">$tot</td>
</tr>
EOINVROW
done

FLEET_STOPPED=$((FLEET_TOTAL - FLEET_RUNNING))
cat >> "$F" <<EOINVTOT
<tr style="background:rgba(15,52,96,0.3);">
<td style="padding:6px 8px;color:#e0e0e0;font-size:12px;font-weight:bold;font-family:'Courier New',monospace;">Fleet</td>
<td style="padding:6px 8px;color:$C_OK;font-size:12px;font-weight:bold;font-family:'Courier New',monospace;">$FLEET_RUNNING</td>
<td style="padding:6px 8px;color:#8899aa;font-size:12px;font-weight:bold;font-family:'Courier New',monospace;">$FLEET_STOPPED</td>
<td style="padding:6px 8px;color:#e0e0e0;font-size:12px;font-weight:bold;font-family:'Courier New',monospace;">$FLEET_UNHEALTHY</td>
<td style="padding:6px 8px;color:#e0e0e0;font-size:12px;font-weight:bold;font-family:'Courier New',monospace;">$FLEET_TOTAL</td>
</tr>
</table>
EOINVTOT

# Per-VM container lists
for ((j=0; j<VM_COUNT; j++)); do
  n=${VM_NAMES[$j]}; ctrs=${VM_CONTAINERS[$j]}
  if [ -n "$ctrs" ]; then
    cat >> "$F" <<EOCTRHEAD
<div style="margin-top:10px;font-weight:bold;color:#8899aa;font-size:11px;margin-bottom:4px;font-family:'Courier New',monospace;">$n containers</div>
<table width="100%" cellpadding="0" cellspacing="0">
EOCTRHEAD
    while IFS='|' read -r cname cstatus cstate; do
      [ -z "$cname" ] && continue
      case "$cstate" in
        running) sc=$C_OK ;; exited) sc=$C_CRIT ;; *) sc=$C_WARN ;;
      esac
      cat >> "$F" <<EOCTRROW
<tr><td style="padding:2px 8px;color:#e0e0e0;font-size:11px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$cname</td>
<td style="padding:2px 8px;color:$sc;font-size:11px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$cstatus</td></tr>
EOCTRROW
    done <<< "$ctrs"
    echo '</table>' >> "$F"
  fi
done

cat >> "$F" <<'EOINV2'
</td></tr></table>
</td></tr>
EOINV2

# ══════════════════════════════════════════════════════════════════════
# 3. OBSERVABILITY — Alerts & Issues
# ══════════════════════════════════════════════════════════════════════
cat >> "$F" <<'EOOBS1'
<tr><td style="padding:8px;">
<table width="100%" cellpadding="0" cellspacing="0" style="background:#16213e;border-radius:6px;">
<tr><td style="padding:12px 16px;background:#0f3460;border-radius:6px 6px 0 0;font-size:14px;font-weight:bold;color:#e0e0e0;font-family:'Courier New',monospace;">3. Observability &mdash; Alerts &amp; Issues</td></tr>
<tr><td style="padding:12px 16px;">
EOOBS1

HAS_ISSUES=false

# Unhealthy containers
for ((j=0; j<VM_COUNT; j++)); do
  unh=${VM_UNHEALTHY[$j]}
  if [ -n "$unh" ]; then
    HAS_ISSUES=true; n=${VM_NAMES[$j]}
    echo "<div style=\"margin-bottom:8px;\"><span style=\"color:$C_CRIT;font-weight:bold;font-size:12px;font-family:'Courier New',monospace;\">Unhealthy on $n:</span>" >> "$F"
    while IFS= read -r c; do
      [ -z "$c" ] && continue
      echo "<div style=\"padding:2px 0 2px 16px;color:$C_CRIT;font-size:12px;font-family:'Courier New',monospace;\">$c</div>" >> "$F"
    done <<< "$unh"
    echo '</div>' >> "$F"
  fi
done

# Exited containers
for ((j=0; j<VM_COUNT; j++)); do
  ex=${VM_EXITED[$j]}
  if [ -n "$ex" ]; then
    HAS_ISSUES=true; n=${VM_NAMES[$j]}
    echo "<div style=\"margin-bottom:8px;\"><span style=\"color:$C_WARN;font-weight:bold;font-size:12px;font-family:'Courier New',monospace;\">Exited on $n:</span>" >> "$F"
    while IFS= read -r c; do
      [ -z "$c" ] && continue
      echo "<div style=\"padding:2px 0 2px 16px;color:$C_WARN;font-size:12px;font-family:'Courier New',monospace;\">$c</div>" >> "$F"
    done <<< "$ex"
    echo '</div>' >> "$F"
  fi
done

# Container restarts (24h)
for ((j=0; j<VM_COUNT; j++)); do
  rst=${VM_RESTARTS[$j]}
  if [ -n "$rst" ]; then
    HAS_ISSUES=true; n=${VM_NAMES[$j]}
    echo "<div style=\"margin-bottom:8px;\"><span style=\"color:$C_WARN;font-weight:bold;font-size:12px;font-family:'Courier New',monospace;\">Restarts (24h) on $n:</span>" >> "$F"
    while IFS='|' read -r cname cnt; do
      [ -z "$cname" ] && continue
      echo "<div style=\"padding:2px 0 2px 16px;color:#e0e0e0;font-size:12px;font-family:'Courier New',monospace;\">$cname (${cnt}x)</div>" >> "$F"
    done <<< "$rst"
    echo '</div>' >> "$F"
  fi
done

# Failed systemd units
for ((j=0; j<VM_COUNT; j++)); do
  fu=${VM_FAILED_UNITS[$j]}
  if [ -n "$fu" ]; then
    HAS_ISSUES=true; n=${VM_NAMES[$j]}
    echo "<div style=\"margin-bottom:8px;\"><span style=\"color:$C_CRIT;font-weight:bold;font-size:12px;font-family:'Courier New',monospace;\">Failed units on $n:</span>" >> "$F"
    while IFS= read -r u; do
      [ -z "$u" ] && continue
      echo "<div style=\"padding:2px 0 2px 16px;color:$C_CRIT;font-size:12px;font-family:'Courier New',monospace;\">$u</div>" >> "$F"
    done <<< "$fu"
    echo '</div>' >> "$F"
  fi
done

# Top resource consumers (docker stats)
cat >> "$F" <<'EOTOP1'
<div style="margin-top:10px;font-weight:bold;color:#e0e0e0;font-size:13px;margin-bottom:6px;font-family:'Courier New',monospace;">Top Resource Consumers</div>
<table width="100%" cellpadding="0" cellspacing="0">
<tr>
<th style="text-align:left;color:#8899aa;font-size:11px;padding:4px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">VM</th>
<th style="text-align:left;color:#8899aa;font-size:11px;padding:4px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Container</th>
<th style="text-align:left;color:#8899aa;font-size:11px;padding:4px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">CPU</th>
<th style="text-align:left;color:#8899aa;font-size:11px;padding:4px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Memory</th>
</tr>
EOTOP1

for ((j=0; j<VM_COUNT; j++)); do
  stats=${VM_CONTAINER_STATS[$j]}; n=${VM_NAMES[$j]}
  if [ -n "$stats" ]; then
    echo "$stats" | head -5 | while IFS='|' read -r cname cpu mem mempct; do
      [ -z "$cname" ] && continue
      cat >> "$F" <<EOTOPROW
<tr>
<td style="padding:3px 8px;color:#8899aa;font-size:11px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$n</td>
<td style="padding:3px 8px;color:#e0e0e0;font-size:11px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$cname</td>
<td style="padding:3px 8px;color:#e0e0e0;font-size:11px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$cpu</td>
<td style="padding:3px 8px;color:#e0e0e0;font-size:11px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$mem</td>
</tr>
EOTOPROW
    done
  fi
done

echo '</table>' >> "$F"

if [ "$HAS_ISSUES" = false ]; then
  echo '<p style="color:#00d68f;font-style:italic;padding:8px 0;font-family:'"'"'Courier New'"'"',monospace;font-size:13px;">All systems nominal &mdash; no alerts.</p>' >> "$F"
fi

cat >> "$F" <<'EOOBS2'
</td></tr></table>
</td></tr>
EOOBS2

# ══════════════════════════════════════════════════════════════════════
# 4. SECURITY — Access Events (24h)
# ══════════════════════════════════════════════════════════════════════
cat >> "$F" <<'EOSEC1'
<tr><td style="padding:8px;">
<table width="100%" cellpadding="0" cellspacing="0" style="background:#16213e;border-radius:6px;">
<tr><td style="padding:12px 16px;background:#0f3460;border-radius:6px 6px 0 0;font-size:14px;font-weight:bold;color:#e0e0e0;font-family:'Courier New',monospace;">4. Security &mdash; Access Events (24h)</td></tr>
<tr><td style="padding:12px 16px;">
<table width="100%" cellpadding="0" cellspacing="0">
<tr>
<th style="text-align:left;color:#8899aa;font-size:11px;padding:6px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">VM</th>
<th style="text-align:left;color:#8899aa;font-size:11px;padding:6px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">SSH Accepted</th>
<th style="text-align:left;color:#8899aa;font-size:11px;padding:6px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">SSH Failed</th>
<th style="text-align:left;color:#8899aa;font-size:11px;padding:6px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Sudo</th>
</tr>
EOSEC1

for ((j=0; j<VM_COUNT; j++)); do
  n=${VM_NAMES[$j]}; sa=${VM_SSH_ACCEPTS[$j]}
  sf=${VM_SSH_FAILS[$j]}; su=${VM_SUDOS[$j]}
  if [ "$sf" -gt 10 ] 2>/dev/null; then sf_color=$C_CRIT; else sf_color=$C_TEXT; fi
  cat >> "$F" <<EOSECROW
<tr>
<td style="padding:6px 8px;color:#e0e0e0;font-size:12px;border-bottom:1px solid rgba(15,52,96,0.5);font-weight:bold;font-family:'Courier New',monospace;">$n</td>
<td style="padding:6px 8px;color:$C_OK;font-size:12px;border-bottom:1px solid rgba(15,52,96,0.5);font-family:'Courier New',monospace;">$sa</td>
<td style="padding:6px 8px;color:$sf_color;font-size:12px;border-bottom:1px solid rgba(15,52,96,0.5);font-family:'Courier New',monospace;">$sf</td>
<td style="padding:6px 8px;color:#e0e0e0;font-size:12px;border-bottom:1px solid rgba(15,52,96,0.5);font-family:'Courier New',monospace;">$su</td>
</tr>
EOSECROW
done

echo '</table>' >> "$F"

# Top failed IPs
for ((j=0; j<VM_COUNT; j++)); do
  sf=${VM_SSH_FAILS[$j]}; tips=${VM_TOP_FAILS[$j]}
  if [ "$sf" -gt 10 ] 2>/dev/null && [ -n "$tips" ]; then
    n=${VM_NAMES[$j]}
    echo "<div style=\"margin-top:8px;\"><span style=\"color:$C_WARN;font-weight:bold;font-size:12px;font-family:'Courier New',monospace;\">Top failed IPs on $n:</span>" >> "$F"
    while IFS='|' read -r fip cnt; do
      [ -z "$fip" ] && continue
      echo "<div style=\"padding:2px 0 2px 16px;color:#e0e0e0;font-size:12px;font-family:'Courier New',monospace;\">$fip (${cnt}x)</div>" >> "$F"
    done <<< "$tips"
    echo '</div>' >> "$F"
  fi
done

cat >> "$F" <<'EOSEC2'
</td></tr></table>
</td></tr>
EOSEC2

# ══════════════════════════════════════════════════════════════════════
# 5. DELIVERY — Backups & Workflows
# ══════════════════════════════════════════════════════════════════════
cat >> "$F" <<'EODEL1'
<tr><td style="padding:8px;">
<table width="100%" cellpadding="0" cellspacing="0" style="background:#16213e;border-radius:6px;">
<tr><td style="padding:12px 16px;background:#0f3460;border-radius:6px 6px 0 0;font-size:14px;font-weight:bold;color:#e0e0e0;font-family:'Courier New',monospace;">5. Delivery &mdash; Backups &amp; Workflows</td></tr>
<tr><td style="padding:12px 16px;">
EODEL1

for ((j=0; j<VM_COUNT; j++)); do
  n=${VM_NAMES[$j]}; bk=${VM_BACKUPS[$j]}
  echo "<div style=\"margin-bottom:10px;\"><div style=\"font-weight:bold;color:#e0e0e0;font-size:12px;margin-bottom:4px;font-family:'Courier New',monospace;\">$n</div>" >> "$F"
  if [ -n "$bk" ]; then
    cat >> "$F" <<'EOBKTBL'
<table width="100%" cellpadding="0" cellspacing="0">
<tr>
<th style="text-align:left;color:#8899aa;font-size:11px;padding:3px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">File</th>
<th style="text-align:left;color:#8899aa;font-size:11px;padding:3px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Size</th>
<th style="text-align:left;color:#8899aa;font-size:11px;padding:3px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Date</th>
</tr>
EOBKTBL
    while IFS='|' read -r fname fsize fdate; do
      [ -z "$fname" ] && continue
      cat >> "$F" <<EOBKROW
<tr>
<td style="padding:3px 8px;color:#e0e0e0;font-size:11px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$fname</td>
<td style="padding:3px 8px;color:#8899aa;font-size:11px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$fsize</td>
<td style="padding:3px 8px;color:#8899aa;font-size:11px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$fdate</td>
</tr>
EOBKROW
    done <<< "$bk"
    echo '</table>' >> "$F"
  else
    echo '<div style="color:#8899aa;font-size:12px;font-style:italic;padding-left:8px;font-family:'"'"'Courier New'"'"',monospace;">No backup files found</div>' >> "$F"
  fi
  echo '</div>' >> "$F"
done

# ── Dagu Workflows Status ──
DAGU_API="http://localhost:8080/api/v1/dags"
DAGU_JSON=$(curl -sf -u "$DAGU_AUTH_BASIC_USERNAME:$DAGU_AUTH_BASIC_PASSWORD" "$DAGU_API" 2>/dev/null || echo "")

if [ -n "$DAGU_JSON" ]; then
  cat >> "$F" <<'EOWF1'
<div style="margin-top:16px;font-weight:bold;color:#e0e0e0;font-size:13px;margin-bottom:6px;font-family:'Courier New',monospace;">Dagu Workflows</div>
<table width="100%" cellpadding="0" cellspacing="0">
<tr>
<th style="text-align:left;color:#8899aa;font-size:11px;padding:4px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Workflow</th>
<th style="text-align:left;color:#8899aa;font-size:11px;padding:4px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Schedule</th>
<th style="text-align:left;color:#8899aa;font-size:11px;padding:4px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Last Status</th>
<th style="text-align:left;color:#8899aa;font-size:11px;padding:4px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Last Run</th>
</tr>
EOWF1

  echo "$DAGU_JSON" | jq -r '
    .DAGs[] |
    [
      (.DAG.Name // .File // "unknown"),
      (.DAG.Schedule[0].Expression // "-"),
      (.Status.StatusText // "none"),
      (.Status.StartedAt // "-")
    ] | join("|")
  ' 2>/dev/null | sort | while IFS='|' read -r wf_name wf_sched wf_status wf_started; do
    [ -z "$wf_name" ] && continue
    case "$wf_status" in
      finished|success) wf_color=$C_OK ;;
      error|failed)     wf_color=$C_CRIT ;;
      running)          wf_color=$C_WARN ;;
      cancel*)          wf_color=$C_WARN ;;
      *)                wf_color=$C_DIM ;;
    esac
    if [ "$wf_started" != "-" ] && [ "$wf_started" != "null" ]; then
      wf_time=$(date -d "$wf_started" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$wf_started")
    else
      wf_time="-"
    fi
    cat >> "$F" <<EOWFROW
<tr>
<td style="padding:3px 8px;color:#e0e0e0;font-size:11px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$wf_name</td>
<td style="padding:3px 8px;color:#8899aa;font-size:11px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$wf_sched</td>
<td style="padding:3px 8px;color:$wf_color;font-size:11px;font-weight:bold;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$wf_status</td>
<td style="padding:3px 8px;color:#8899aa;font-size:11px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$wf_time</td>
</tr>
EOWFROW
  done
  echo '</table>' >> "$F"
else
  echo '<div style="margin-top:16px;color:#8899aa;font-size:12px;font-style:italic;font-family:'"'"'Courier New'"'"',monospace;">Could not fetch Dagu workflow status</div>' >> "$F"
fi

cat >> "$F" <<'EODEL2'
<div style="margin-top:8px;padding:8px;background:rgba(15,52,96,0.3);border-radius:4px;">
<span style="color:#8899aa;font-size:12px;font-family:'Courier New',monospace;">Dagu Dashboard: </span>
<a href="http://10.0.0.3:8070" style="color:#00d68f;font-size:12px;font-family:'Courier New',monospace;">http://10.0.0.3:8070</a>
</div>
</td></tr></table>
</td></tr>
EODEL2

# ══════════════════════════════════════════════════════════════════════
# 6. FINOPS — Resource Utilization
# ══════════════════════════════════════════════════════════════════════
cat >> "$F" <<'EOFIN1'
<tr><td style="padding:8px;">
<table width="100%" cellpadding="0" cellspacing="0" style="background:#16213e;border-radius:6px;">
<tr><td style="padding:12px 16px;background:#0f3460;border-radius:6px 6px 0 0;font-size:14px;font-weight:bold;color:#e0e0e0;font-family:'Courier New',monospace;">6. FinOps &mdash; Resource Utilization</td></tr>
<tr><td style="padding:12px 16px;">
<div style="font-weight:bold;color:#e0e0e0;font-size:13px;margin-bottom:6px;font-family:'Courier New',monospace;">Docker Disk Usage</div>
<table width="100%" cellpadding="0" cellspacing="0">
<tr>
<th style="text-align:left;color:#8899aa;font-size:11px;padding:4px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">VM</th>
<th style="text-align:left;color:#8899aa;font-size:11px;padding:4px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Type</th>
<th style="text-align:left;color:#8899aa;font-size:11px;padding:4px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Count</th>
<th style="text-align:left;color:#8899aa;font-size:11px;padding:4px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Size</th>
<th style="text-align:left;color:#8899aa;font-size:11px;padding:4px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Reclaimable</th>
</tr>
EOFIN1

for ((j=0; j<VM_COUNT; j++)); do
  n=${VM_NAMES[$j]}; ddf=${VM_DOCKER_DFS[$j]}
  if [ -n "$ddf" ]; then
    first_row=true
    while IFS='|' read -r dtype dcount dsize dreclaim; do
      [ -z "$dtype" ] && continue
      if $first_row; then vm_cell="$n"; first_row=false; else vm_cell=""; fi
      cat >> "$F" <<EOFINROW
<tr>
<td style="padding:3px 8px;color:#e0e0e0;font-size:11px;border-bottom:1px solid rgba(15,52,96,0.3);font-weight:bold;font-family:'Courier New',monospace;">$vm_cell</td>
<td style="padding:3px 8px;color:#8899aa;font-size:11px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$dtype</td>
<td style="padding:3px 8px;color:#e0e0e0;font-size:11px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$dcount</td>
<td style="padding:3px 8px;color:#e0e0e0;font-size:11px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$dsize</td>
<td style="padding:3px 8px;color:#8899aa;font-size:11px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:'Courier New',monospace;">$dreclaim</td>
</tr>
EOFINROW
    done <<< "$ddf"
  fi
done

echo '</table>' >> "$F"

# Fleet utilization bars
cat >> "$F" <<'EOUTIL1'
<div style="margin-top:12px;font-weight:bold;color:#e0e0e0;font-size:13px;margin-bottom:6px;font-family:'Courier New',monospace;">Fleet Utilization</div>
<table width="100%" cellpadding="0" cellspacing="0">
<tr>
<th style="text-align:left;color:#8899aa;font-size:11px;padding:4px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">VM</th>
<th style="text-align:left;color:#8899aa;font-size:11px;padding:4px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Memory</th>
<th style="text-align:left;color:#8899aa;font-size:11px;padding:4px 8px;border-bottom:1px solid #0f3460;font-family:'Courier New',monospace;">Disk</th>
</tr>
EOUTIL1

for ((j=0; j<VM_COUNT; j++)); do
  n=${VM_NAMES[$j]}; mp=${VM_MEM_PCTS[$j]}; dp=${VM_DISK_PCTS[$j]}
  mbar=$(progress_bar "$mp"); dbar=$(progress_bar "$dp")
  cat >> "$F" <<EOUTILROW
<tr>
<td style="padding:4px 8px;color:#e0e0e0;font-size:12px;border-bottom:1px solid rgba(15,52,96,0.3);font-weight:bold;font-family:'Courier New',monospace;">$n</td>
<td style="padding:4px 8px;border-bottom:1px solid rgba(15,52,96,0.3);">$mbar</td>
<td style="padding:4px 8px;border-bottom:1px solid rgba(15,52,96,0.3);">$dbar</td>
</tr>
EOUTILROW
done

cat >> "$F" <<EOFINTOT
</table>
<div style="margin-top:10px;padding:8px;background:rgba(15,52,96,0.3);border-radius:4px;color:#8899aa;font-size:12px;font-family:'Courier New',monospace;">
Fleet totals: <span style="color:#e0e0e0;">$FLEET_RUNNING running</span> / <span style="color:#e0e0e0;">$FLEET_TOTAL total containers</span>
</div>
EOFINTOT

cat >> "$F" <<'EOFIN2'
</td></tr></table>
</td></tr>
EOFIN2

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

# ── Send email via SMTP ──
curl -s --url "smtp://mailu-smtp-1:25" \
  --mail-from "no-reply@diegonmarcos.com" \
  --mail-rcpt "me@diegonmarcos.com" \
  -T "$F"
rm -f "$F"
echo "C3 Daily Ops Report sent for $DATE"
