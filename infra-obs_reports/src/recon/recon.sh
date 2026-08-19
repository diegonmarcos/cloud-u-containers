#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# External friend-hack recon — runs OUTSIDE the WireGuard mesh, UNAUTHENTICATED,
# against the PUBLIC attack surface only. This is the Kali/pentest-tool layer of
# cloud-security.yml (complements the in-house Rust sec-network/sec-data/url).
#
# Data-driven: every target is derived from the consolidated cloud-data JSON
# (public VM IPs + service domains) — nothing hardcoded except the apex domain.
# Every tool is OPTIONAL: if a binary isn't present, that stage is skipped (the
# image build installs them best-effort). Findings are the REPORT, not a failure
# — the script always exits 0; the caller decides policy on the artifact.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

OUT="${RECON_OUT:-/work/dist/recon}"
REPO="${REPO_ROOT:-/work}"
CONS="${CONSOLIDATED:-$REPO/cloud/1_cloud-configs/dist/_cloud-data-consolidated.json}"
APEX="${RECON_APEX:-diegonmarcos.com}"
mkdir -p "$OUT"

have() { command -v "$1" >/dev/null 2>&1; }
log()  { printf '[recon] %s\n' "$*"; }

# ── targets from the consolidated catalog (data-driven) ──────────────────────
IPS=(); DOMAINS=()
if [ -f "$CONS" ] && have jq; then
  mapfile -t IPS     < <(jq -r '.vms[]? | (.public_ip // .ip // empty)' "$CONS" 2>/dev/null | grep -E '^[0-9]+\.' | sort -u)
  mapfile -t DOMAINS < <(jq -r '.services[]?.domain // empty, .vms[]?.domains[]? // empty, .vms[]?.domain // empty' "$CONS" 2>/dev/null | grep -E '\.[a-z]' | sort -u)
else
  # R5: Fail loud — silently falling back to apex-only masks the missing catalog.
  # A recon run with no VM IPs and only the apex produces misleading findings
  # (would look green when 3 VMs are actually unreachable). Operators MUST know.
  log "FATAL: consolidated catalog not found at $CONS"
  log "Set CONSOLIDATED= or REPO_ROOT= to a path containing _cloud-data-consolidated.json."
  log "Refusing to run recon without data-driven targets."
  exit 1
fi
# Service domains come from the catalog above (data-driven). The apex is the one
# architectural constant (env-overridable) — included so the public edge is always
# probed even if the catalog is unavailable.
DOMAINS+=("$APEX")
mapfile -t DOMAINS < <(printf '%s\n' "${DOMAINS[@]}" | grep -E '\.[a-z]' | sort -u)
printf '%s\n' "${DOMAINS[@]}" > "$OUT/domains.txt"
printf '%s\n' "${IPS[@]}"     > "$OUT/ips.txt"
log "targets: ${#IPS[@]} public IPs, ${#DOMAINS[@]} domains"

# ── 1. nmap — service/version scan of the public IPs ─────────────────────────
if have nmap && [ "${#IPS[@]}" -gt 0 ]; then
  log "nmap -sV (top-200) on ${#IPS[@]} IPs"
  nmap -Pn -sV -T4 --top-ports 200 -oN "$OUT/nmap.txt" -oX "$OUT/nmap.xml" "${IPS[@]}" >/dev/null 2>&1 || true
else log "skip nmap (tool or targets absent)"; fi

# ── 2. testssl.sh — TLS posture of each public :443 ──────────────────────────
if have testssl.sh; then
  for d in "${DOMAINS[@]}"; do
    timeout 200 testssl.sh --quiet --color 0 --jsonfile "$OUT/testssl-$d.json" "https://$d" >/dev/null 2>&1 || true
  done
  log "testssl done (${#DOMAINS[@]} domains)"
else log "skip testssl"; fi

# ── 3. httpx — live-host + tech fingerprint of the surface ───────────────────
if have httpx; then
  httpx -silent -title -status-code -tech-detect -o "$OUT/httpx.txt" -l "$OUT/domains.txt" >/dev/null 2>&1 || true
  log "httpx done"
else log "skip httpx"; fi

# ── 4. nuclei — CVE / misconfig templates against the surface ────────────────
if have nuclei; then
  nuclei -silent -severity low,medium,high,critical -jsonl -o "$OUT/nuclei.jsonl" -l "$OUT/domains.txt" >/dev/null 2>&1 || true
  log "nuclei done"
else log "skip nuclei"; fi

# ── 5. dnsx — DNS surface / resolution ───────────────────────────────────────
if have dnsx; then
  dnsx -silent -a -resp -o "$OUT/dnsx.txt" -l "$OUT/domains.txt" >/dev/null 2>&1 || true
  log "dnsx done"
else log "skip dnsx"; fi

# ── 6. gitleaks — secret-leak scan of the PUBLIC repos ───────────────────────
if have gitleaks; then
  for r in cloud cloud-data; do
    [ -d "$REPO/$r" ] && gitleaks detect --source "$REPO/$r" --no-git \
        --report-format json --report-path "$OUT/gitleaks-$r.json" >/dev/null 2>&1 || true
  done
  log "gitleaks done"
else log "skip gitleaks"; fi

# ── summary ──────────────────────────────────────────────────────────────────
{
  echo "# External Recon (friend-hack · no mesh · unauthenticated) — $(date -u +%FT%TZ)"
  echo
  echo "## Open public services (nmap)"
  grep -E '^[0-9]+/tcp +open' "$OUT/nmap.txt" 2>/dev/null | sort -u | sed 's/^/- /' || echo "- (nmap not run)"
  echo
  echo "## Live hosts (httpx)"
  sed 's/^/- /' "$OUT/httpx.txt" 2>/dev/null | head -50 || echo "- (httpx not run)"
  echo
  echo "## CVE / misconfig findings (nuclei)"
  if [ -s "$OUT/nuclei.jsonl" ]; then
    jq -r '"- [\(.info.severity)] \(.["template-id"]) @ \(.host)"' "$OUT/nuclei.jsonl" 2>/dev/null | sort -u
  else echo "- (none)"; fi
  echo
  echo "## Secret leaks in public repos (gitleaks)"
  tot=0
  for f in "$OUT"/gitleaks-*.json; do
    [ -s "$f" ] || continue
    c=$(jq 'length' "$f" 2>/dev/null || echo 0); tot=$((tot + ${c:-0}))
  done
  echo "- $tot potential secret(s) flagged (review the per-repo gitleaks JSON)"
} > "$OUT/recon-summary.md"

cat "$OUT/recon-summary.md"
log "complete → $OUT"
exit 0
