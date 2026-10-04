#!/bin/sh
# url-triage.sh — layered single-URL probe (L3 → L4 → L5 → L6 → L7 → Messaging).
#
# A sibling of server-scanning.sh. This script answers "what is THIS endpoint
# really doing?"; server-scanning.sh answers "what ports are open on this host?".
#
# URL scheme drives the protocol probe:
#   https://host[:port]/path   → 443, HTTPS,    client-first
#   http://host[:port]/path    → 80,  HTTP,     client-first
#   smtps://host[:port]        → 465, SMTPS,    server-first (post-TLS)
#   smtp://host[:port]         → 25,  SMTP,     server-first cleartext
#   submission://host[:port]   → 587, SMTP-STARTTLS, server-first
#   imaps://host[:port]        → 993, IMAPS,    server-first (post-TLS)
#   imap://host[:port]         → 143, IMAP,     server-first cleartext
#   pop3s://host[:port]        → 995, POP3S,    server-first (post-TLS)
#   pop3://host[:port]         → 110, POP3,     server-first cleartext
#   ssh://host[:port]          → 22,  SSH,      server-first
#   ftp://host[:port]          → 21,  FTP,      server-first
#   tcp://host:port            → raw probe, autodetect speaker
#
# Output (per run):
#   ~/.triage/<host>-<port>-<UTC>/
#     report.json            canonical metadata (single source of truth)
#     dialogue.txt           full Messaging-Layer transcript (always)
#     openssl-handshake.txt  L5/L6 raw evidence (TLS schemes only)
#     body.<ext>             HTTPS/HTTP response body, MIME-driven extension
#
# Console output is rendered FROM report.json.

set -u

###############################################################################
# Args — $1 = URL/host
###############################################################################

usage() {
    cat <<'USAGE'
Usage: url-triage.sh <url> [--no-color] [--out DIR]
       url-triage.sh --self-test

Examples:
  url-triage.sh https://api.diegonmarcos.com/c3-api/health
  url-triage.sh smtps://mail.diegonmarcos.com:465
  url-triage.sh imaps://mail.diegonmarcos.com
  url-triage.sh submission://mail.diegonmarcos.com:587
  url-triage.sh ssh://gcp-proxy
  url-triage.sh tcp://1.2.3.4:9999      # raw TCP, autodetect first-speaker
  url-triage.sh diegonmarcos.com         # bare host → defaults to https://

Layers:
  L3 — DNS / WHOIS-ASN / PTR / PATH-trace
  L4 — single-port reachability (no full scan; use server-scanning.sh for that)
  L5 — TLS handshake (SNI, ALPN, version, cipher, session resumption)
  L6 — Certificate (subject, SANs, dates, sig algo, public key, fingerprint)
  L7 — Application protocol identification (HTTP body identity / banner type)
  Messaging — Protocol dialogue (first/second poke pattern, full transcript)
USAGE
}

SELF_TEST=0
case "${1:-}" in
    "")          usage; exit 2 ;;
    -h|--help)   usage; exit 0 ;;
    --self-test) SELF_TEST=1; INPUT="https://example.com"; shift ;;
    -*)          printf 'url-triage: first arg must be a URL/host\n' >&2; usage >&2; exit 2 ;;
    *)           INPUT=$1; shift ;;
esac

USE_COLOR="auto"
OUT_OVERRIDE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --no-color) USE_COLOR="no" ;;
        --out=*)    OUT_OVERRIDE=${1#--out=} ;;
        --out)      shift; OUT_OVERRIDE=${1:-} ;;
        -h|--help)  usage; exit 0 ;;
        *)          printf 'url-triage: unknown flag: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

###############################################################################
# URL scheme parsing — drives protocol selection (DATA section, FIRE RULE 4).
###############################################################################
# Schema: SCHEME → {PORT, USE_TLS, STARTTLS_MODE, FIRST_SPEAKER, PROTO_LABEL}

# Default scheme when bare hostname is given:
INPUT_LC=$(printf '%s' "$INPUT" | tr 'A-Z' 'a-z')
case "$INPUT_LC" in
    *://*) : ;;
    *)            INPUT_LC="https://$INPUT_LC" ;;
esac

SCHEME=${INPUT_LC%%://*}
REST=${INPUT_LC#*://}
HOSTPORT=${REST%%/*}
PATH_PART=${REST#"$HOSTPORT"}
case "$PATH_PART" in
    "$REST"|"") PATH_PART="/" ;;
esac

HOST=${HOSTPORT%%:*}
PORT_EXPLICIT=""
case "$HOSTPORT" in
    *:*) PORT_EXPLICIT=${HOSTPORT#*:} ;;
esac

USE_TLS=0
STARTTLS_MODE=""
FIRST_SPEAKER=server
PROTO_LABEL=""
case "$SCHEME" in
    https)      PORT_DEFAULT=443; USE_TLS=1;                       FIRST_SPEAKER=client; PROTO_LABEL=HTTPS ;;
    http)       PORT_DEFAULT=80;  USE_TLS=0;                       FIRST_SPEAKER=client; PROTO_LABEL=HTTP ;;
    smtps)      PORT_DEFAULT=465; USE_TLS=1;                       FIRST_SPEAKER=server; PROTO_LABEL=SMTPS ;;
    smtp)       PORT_DEFAULT=25;  USE_TLS=0;                       FIRST_SPEAKER=server; PROTO_LABEL=SMTP ;;
    submission) PORT_DEFAULT=587; USE_TLS=1; STARTTLS_MODE=smtp;   FIRST_SPEAKER=server; PROTO_LABEL='SMTP+STARTTLS' ;;
    imaps)      PORT_DEFAULT=993; USE_TLS=1;                       FIRST_SPEAKER=server; PROTO_LABEL=IMAPS ;;
    imap)       PORT_DEFAULT=143; USE_TLS=0;                       FIRST_SPEAKER=server; PROTO_LABEL=IMAP ;;
    pop3s)      PORT_DEFAULT=995; USE_TLS=1;                       FIRST_SPEAKER=server; PROTO_LABEL=POP3S ;;
    pop3)       PORT_DEFAULT=110; USE_TLS=0;                       FIRST_SPEAKER=server; PROTO_LABEL=POP3 ;;
    ssh)        PORT_DEFAULT=22;  USE_TLS=0;                       FIRST_SPEAKER=server; PROTO_LABEL=SSH ;;
    ftp)        PORT_DEFAULT=21;  USE_TLS=0;                       FIRST_SPEAKER=server; PROTO_LABEL=FTP ;;
    tcp)        PORT_DEFAULT=0;   USE_TLS=0;                       FIRST_SPEAKER=auto;   PROTO_LABEL='TCP-raw' ;;
    *)          printf 'url-triage: unsupported scheme: %s\n' "$SCHEME" >&2; usage >&2; exit 2 ;;
esac

PORT=${PORT_EXPLICIT:-$PORT_DEFAULT}
if [ "$PORT" = 0 ]; then
    printf 'url-triage: tcp:// requires explicit port (e.g. tcp://host:9999)\n' >&2
    exit 2
fi

IS_IP=0
case "$HOST" in
    [0-9]*.[0-9]*.[0-9]*.[0-9]*) IS_IP=1 ;;
esac
if [ "$IS_IP" = 1 ]; then APEX=""; else
    APEX=$(printf '%s' "$HOST" | awk -F. '{n=NF; if (n>=2) printf "%s.%s", $(n-1), $n; else printf "%s", $0}')
fi

###############################################################################
# Color
###############################################################################

if [ "$USE_COLOR" = "auto" ]; then
    if [ -t 1 ]; then USE_COLOR=yes; else USE_COLOR=no; fi
fi
if [ "$USE_COLOR" = "yes" ]; then
    C_BOLD=$(printf '\033[1m');     C_DIM=$(printf '\033[2m')
    C_RED=$(printf '\033[1;31m');   C_GREEN=$(printf '\033[1;32m')
    C_YELLOW=$(printf '\033[1;33m'); C_BLUE=$(printf '\033[1;34m')
    C_MAGENTA=$(printf '\033[1;35m'); C_CYAN=$(printf '\033[1;36m')
    C_OFF=$(printf '\033[0m')
else
    C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""
    C_BLUE=""; C_MAGENTA=""; C_CYAN=""; C_OFF=""
fi

###############################################################################
# Preflight
###############################################################################

have() { command -v "$1" >/dev/null 2>&1; }

if ! have jq; then printf 'url-triage: jq required\n' >&2; exit 1; fi
HAVE_DIG=0;        have dig        && HAVE_DIG=1
HAVE_MTR=0;        have mtr        && HAVE_MTR=1
HAVE_NC=0;         have nc         && HAVE_NC=1
HAVE_OPENSSL=0;    have openssl    && HAVE_OPENSSL=1
HAVE_CURL=0;       have curl       && HAVE_CURL=1
HAVE_WHOIS=0;      have whois      && HAVE_WHOIS=1
HAVE_SUDO=0;       have sudo       && HAVE_SUDO=1
HAVE_TRACEPATH=0;  have tracepath  && HAVE_TRACEPATH=1

###############################################################################
# Workspace + output dir
###############################################################################

TS=$(date -u +%Y%m%dT%H%M%SZ)
SAFE_HOST=$(printf '%s' "$HOST" | tr '/:?#' '____')
# Resolve script's own directory for colocated dist/ (matches cloud-data
# `reports/<name>/dist/...` convention). Per-run subdirs are gitignored.
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -n "$OUT_OVERRIDE" ]; then
    OUT_DIR=$OUT_OVERRIDE
else
    OUT_DIR="$SCRIPT_DIR/dist/${SAFE_HOST}-${PORT}-${TS}"
fi
mkdir -p "$OUT_DIR"

TMP=$(mktemp -d 2>/dev/null) || TMP="/tmp/url-triage.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP

REPORT_JSON="$OUT_DIR/report.json"
DIALOGUE="$OUT_DIR/dialogue.txt"
OPENSSL_LOG="$OUT_DIR/openssl-handshake.txt"

###############################################################################
# L3 — Network / IP
###############################################################################

worker_l3_dns() {
    OUT=$TMP/l3-dns.out
    {
        if [ "$IS_IP" = 1 ]; then printf '  (input is IP — DNS skipped)\n'; return 0; fi
        if [ "$HAVE_DIG" = 0 ]; then printf '  dig not installed\n'; return 0; fi
        printf -- '--- A/AAAA/CNAME (%s) ---\n' "$HOST"
        r=$(dig +noall +answer +time=3 +tries=1 "$HOST" A AAAA CNAME 2>/dev/null)
        [ -n "$r" ] && printf '%s\n' "$r" || printf '  (no answer)\n'
        printf -- '\n--- MX/TXT/DMARC/MTA-STS/NS/CAA (%s) ---\n' "$APEX"
        for q in MX TXT NS CAA; do
            r=$(dig +noall +answer +time=3 +tries=1 "$APEX" "$q" 2>/dev/null)
            [ -n "$r" ] && printf '%s\n' "$r"
        done
        r=$(dig +noall +answer +time=3 +tries=1 "_dmarc.$APEX" TXT 2>/dev/null)
        [ -n "$r" ] && printf '%s\n' "$r"
        r=$(dig +noall +answer +time=3 +tries=1 "_mta-sts.$APEX" TXT 2>/dev/null)
        [ -n "$r" ] && printf '%s\n' "$r"
        if dig +dnssec +noall +answer +time=3 +tries=1 "$APEX" A 2>/dev/null | grep -q RRSIG; then
            printf '  DNSSEC: signed\n'
        else
            printf '  DNSSEC: not signed\n'
        fi
    } > "$OUT" 2>&1
}

worker_l3_whois() {
    OUT=$TMP/l3-whois.out
    {
        if [ "$IS_IP" = 1 ]; then
            IP=$HOST
        elif [ "$HAVE_DIG" = 1 ]; then
            IP=$(dig +short +time=3 +tries=1 "$HOST" A 2>/dev/null | awk '/^[0-9]/ {print; exit}')
            [ -z "$IP" ] && { printf '  (no A record)\n'; return 0; }
        else
            printf '  dig missing\n'; return 0
        fi
        printf 'Resolved IP: %s\n' "$IP"
        if [ "$HAVE_WHOIS" = 1 ]; then
            printf -- '--- ASN / Org (Team Cymru) ---\n'
            whois -h whois.cymru.com " -v $IP" 2>/dev/null | awk 'NR<=2 {print "  "$0}'
        fi
        if [ "$HAVE_DIG" = 1 ]; then
            printf -- '--- Reverse DNS (PTR) ---\n'
            r=$(dig +noall +answer +time=3 +tries=1 -x "$IP" 2>/dev/null)
            [ -n "$r" ] && printf '%s\n' "$r" || printf '  (no PTR)\n'
        fi
    } > "$OUT" 2>&1
}

worker_l3_path() {
    OUT=$TMP/l3-path.out
    {
        if [ "$HAVE_MTR" = 1 ] && [ "$HAVE_SUDO" = 1 ] && sudo -n true 2>/dev/null; then
            printf -- '--- mtr -T -P %s (TCP, sudo) ---\n' "$PORT"
            MTR_OUT=$(sudo mtr -T -P "$PORT" -n -r -c 3 "$HOST" 2>&1) && { printf '%s\n' "$MTR_OUT"; return 0; }
        fi
        if [ "$HAVE_MTR" = 1 ]; then
            MTR_OUT=$(mtr -n -r -c 3 "$HOST" 2>&1)
            if [ "$?" = 0 ] && ! printf '%s' "$MTR_OUT" | grep -qE 'Failure|not implemented|Operation not permitted'; then
                printf -- '--- mtr (ICMP) ---\n%s\n' "$MTR_OUT"; return 0
            fi
        fi
        if [ "$HAVE_TRACEPATH" = 1 ]; then
            TP=$(tracepath -n -m 20 "$HOST" 2>&1)
            if [ "$?" = 0 ] && ! printf '%s' "$TP" | grep -qE 'Operation not permitted|not implemented'; then
                printf -- '--- tracepath -n (SOCK_DGRAM) ---\n%s\n' "$TP"; return 0
            fi
        fi
        printf '  (no usable traceroute — Termux/Android blocks raw sockets, no sudo, no tracepath)\n'
    } > "$OUT" 2>&1
}

###############################################################################
# L4 — single-port reachability
###############################################################################

worker_l4_port() {
    OUT=$TMP/l4-port.out
    {
        printf 'Single-port probe: %s:%s (TCP)\n' "$HOST" "$PORT"
        if [ "$HAVE_NC" = 1 ]; then
            if nc -z -w 4 "$HOST" "$PORT" 2>/dev/null; then
                printf '  state: OPEN\n'
            else
                printf '  state: CLOSED or FILTERED\n'
            fi
        else
            printf '  nc not installed — cannot probe\n'
        fi
        printf '\nFor full port discovery (1-20005) on this host:\n'
        printf '  server-scanning.sh %s --banner\n' "$HOST"
    } > "$OUT" 2>&1
}

###############################################################################
# L5 / L6 — TLS handshake + certificate
###############################################################################

worker_l56_tls() {
    OUT5=$TMP/l5-session.out
    OUT6=$TMP/l6-presentation.out
    if [ "$USE_TLS" = 0 ]; then
        printf '  (scheme is cleartext — no TLS to inspect at L5/L6)\n' > "$OUT5"
        printf '  (scheme is cleartext — no certificate)\n' > "$OUT6"
        return 0
    fi
    if [ "$HAVE_OPENSSL" = 0 ]; then
        printf '  openssl missing\n' > "$OUT5"; cp "$OUT5" "$OUT6"; return 0
    fi
    if [ -n "$STARTTLS_MODE" ]; then
        STARTTLS_ARG="-starttls $STARTTLS_MODE"
    else
        STARTTLS_ARG=""
    fi
    # Primary handshake — bounded to ~6 s. On Termux there's no `timeout(1)`
    # POSIX-portable, so we bound via openssl's own `-connect_timeout` (modern
    # openssl) and the script's own background+kill if needed.
    # shellcheck disable=SC2086
    ( printf 'Q\n' | openssl s_client -showcerts -alpn 'h2,http/1.1,imap,smtp,pop3' \
        $STARTTLS_ARG -servername "$HOST" -connect "$HOST:$PORT" \
        2> /dev/null > "$OPENSSL_LOG" ) &
    SC_PID=$!
    ( sleep 6; kill -TERM "$SC_PID" 2>/dev/null ) &
    GUARD_PID=$!
    wait "$SC_PID" 2>/dev/null
    kill -TERM "$GUARD_PID" 2>/dev/null
    if [ ! -s "$OPENSSL_LOG" ]; then
        {
            printf '  TLS handshake FAILED (port closed/filtered, SNI rejected, or STARTTLS unsupported).\n'
            printf '  Skipping protocol-version enumeration (4 more probes would each time out — saves ~120s).\n'
        } > "$OUT5"
        cp "$OUT5" "$OUT6"; return 0
    fi

    # L5 — session
    {
        ALPN=$(awk -F': ' '/^ALPN protocol/ {print $2; exit}' "$OPENSSL_LOG")
        VERSION=$(awk -F': ' '/Protocol[[:space:]]*:/ {print $2; exit}' "$OPENSSL_LOG")
        CIPHER=$(awk -F': ' '/^[[:space:]]*Cipher[[:space:]]*:/ {print $2; exit}' "$OPENSSL_LOG")
        SESSION_REUSE=$(awk '/Reused, / {print "reused"; exit} /New, / {print "new"; exit}' "$OPENSSL_LOG")
        TICKET=$(awk '/TLS session ticket lifetime hint:/ {print $0; exit}' "$OPENSSL_LOG")
        printf '  SNI sent:           %s\n' "$HOST"
        printf '  ALPN negotiated:    %s\n' "${ALPN:-(none)}"
        printf '  TLS version:        %s\n' "${VERSION:-?}"
        printf '  Cipher suite:       %s\n' "${CIPHER:-?}"
        printf '  Session:            %s\n' "${SESSION_REUSE:-?}"
        [ -n "$TICKET" ] && printf '  %s\n' "$TICKET"
        printf '  Protocol enumeration:\n'
        for VER in tls1_3 tls1_2 tls1_1 tls1; do
            # shellcheck disable=SC2086
            R=$(printf 'Q\n' | openssl s_client -"$VER" $STARTTLS_ARG \
                -servername "$HOST" -connect "$HOST:$PORT" 2>/dev/null \
                | awk -F': ' '/^[[:space:]]*Cipher[[:space:]]*:/ && $2!="" && $2!="0000" {print $2; exit}')
            if [ -n "$R" ]; then
                printf '    OK    %-8s  cipher=%s\n' "$VER" "$R"
            else
                printf '    FAIL  %-8s\n' "$VER"
            fi
        done
    } > "$OUT5"

    # L6 — presentation
    {
        openssl x509 -in "$OPENSSL_LOG" -noout \
            -subject -issuer -dates -ext subjectAltName -fingerprint -sha256 \
            2>/dev/null \
            | awk '
                /^subject=/    {print "  Subject:        " substr($0, 9)}
                /^issuer=/     {print "  Issuer:         " substr($0, 8)}
                /^notBefore=/  {print "  NotBefore:      " substr($0, 11)}
                /^notAfter=/   {print "  NotAfter:       " substr($0, 10)}
                /SHA256 Fingerprint/ {print "  SHA256 fp:      " $NF}
                /Subject Alternative Name/ {sans=1; next}
                sans==1 && /^[[:space:]]/  {print "  SAN:" $0; sans=0}
            '
        SIG=$(openssl x509 -in "$OPENSSL_LOG" -noout -text 2>/dev/null \
              | awk '/Signature Algorithm:/ {print $3; exit}')
        PUBKEY=$(openssl x509 -in "$OPENSSL_LOG" -noout -text 2>/dev/null \
              | awk '/Public Key Algorithm:/ {algo=$NF; getline; size=$0; print algo "  " size; exit}')
        [ -n "$SIG" ]    && printf '  Sig algo:       %s\n' "$SIG"
        [ -n "$PUBKEY" ] && printf '  PubKey:         %s\n' "$PUBKEY"
        if grep -q '^OCSP response:' "$OPENSSL_LOG"; then
            printf '  OCSP staple:    present\n'
        else
            printf '  OCSP staple:    (none)\n'
        fi
        if grep -q 'CT Certificate Transparency' "$OPENSSL_LOG"; then
            printf '  CT SCT(s):      present\n'
        else
            printf '  CT SCT(s):      (none in handshake)\n'
        fi
    } > "$OUT6"
}

###############################################################################
# L7 — Application protocol identification (label only; deep dive in Messaging)
###############################################################################

worker_l7_app() {
    OUT=$TMP/l7-app.out
    {
        printf 'Scheme:         %s\n' "$SCHEME"
        printf 'Port:           %s\n' "$PORT"
        printf 'Protocol label: %s\n' "$PROTO_LABEL"
        printf 'First speaker:  %s\n' "$FIRST_SPEAKER"
        printf 'TLS:            %s\n' "$([ "$USE_TLS" = 1 ] && echo yes || echo no)"
        [ -n "$STARTTLS_MODE" ] && printf 'STARTTLS mode:  %s\n' "$STARTTLS_MODE"
    } > "$OUT" 2>&1
}

###############################################################################
# Messaging Layer — protocol-specific dialogue (first/second poke)
###############################################################################

ml_pipe() {
    # $1 = channel: 'tls' or 'raw'
    # $2 = STARTTLS mode (empty if implicit TLS or raw)
    case "$1" in
        tls)
            if [ -n "$2" ]; then
                # shellcheck disable=SC2086
                openssl s_client -quiet -crlf -starttls "$2" \
                    -servername "$HOST" -connect "$HOST:$PORT" 2>&1
            else
                openssl s_client -quiet -crlf -servername "$HOST" \
                    -connect "$HOST:$PORT" 2>&1
            fi
            ;;
        raw)
            nc -w 8 "$HOST" "$PORT" 2>&1
            ;;
    esac
}

ml_http() {
    BODY_TMP=$TMP/body.raw
    HEADERS_TMP=$TMP/headers.raw
    URL_FULL="${SCHEME}://${HOST}:${PORT}${PATH_PART}"
    {
        printf '=== Messaging Layer: %s ===\n' "$PROTO_LABEL"
        printf 'Pattern: client-first (we send GET, server replies)\n\n'
        printf '> GET %s HTTP/1.1\n> Host: %s\n> User-Agent: url-triage/1.0\n>\n\n' \
               "$PATH_PART" "$HOST"
    } > "$DIALOGUE"
    if [ "$HAVE_CURL" = 0 ]; then
        printf '  curl not installed\n' > "$TMP/messaging.out"; return 0
    fi
    curl -sS -L --max-time 15 -A 'url-triage/1.0' \
         -D "$HEADERS_TMP" -o "$BODY_TMP" \
         -w 'TIMING|%{time_namelookup}|%{time_connect}|%{time_appconnect}|%{time_starttransfer}|%{time_total}|%{http_code}|%{url_effective}|%{num_redirects}|%{http_version}|%{size_download}|%{content_type}|%{remote_ip}|%{remote_port}\n' \
         "$URL_FULL" > "$TMP/curl.meta" 2>&1
    {
        printf '< === Response headers ===\n'
        sed 's/^/< /' "$HEADERS_TMP"
        printf '\n< === Response body (first 4 KiB) ===\n'
        head -c 4096 "$BODY_TMP" | sed 's/^/< /'
        printf '\n< === Body truncated (full saved to body file) ===\n'
    } >> "$DIALOGUE"

    T_LINE=$(grep '^TIMING|' "$TMP/curl.meta" | tail -1)
    T_DNS=$(printf  '%s' "$T_LINE" | cut -d'|' -f2)
    T_CONN=$(printf '%s' "$T_LINE" | cut -d'|' -f3)
    T_TLS=$(printf  '%s' "$T_LINE" | cut -d'|' -f4)
    T_TTFB=$(printf '%s' "$T_LINE" | cut -d'|' -f5)
    T_TOTAL=$(printf '%s' "$T_LINE" | cut -d'|' -f6)
    H_CODE=$(printf '%s' "$T_LINE" | cut -d'|' -f7)
    H_URL=$(printf  '%s' "$T_LINE" | cut -d'|' -f8)
    H_REDIR=$(printf '%s' "$T_LINE" | cut -d'|' -f9)
    H_VER=$(printf  '%s' "$T_LINE" | cut -d'|' -f10)
    H_SIZE=$(printf '%s' "$T_LINE" | cut -d'|' -f11)
    H_CT=$(printf   '%s' "$T_LINE" | cut -d'|' -f12)
    H_RIP=$(printf  '%s' "$T_LINE" | cut -d'|' -f13)
    H_RPORT=$(printf '%s' "$T_LINE" | cut -d'|' -f14)

    case "$H_CT" in
        text/html*)               EXT=html ;;
        application/json*)        EXT=json ;;
        application/xml*|text/xml*) EXT=xml ;;
        text/plain*)              EXT=txt ;;
        text/css*)                EXT=css ;;
        text/javascript*|application/javascript*) EXT=js ;;
        image/png*)               EXT=png ;;
        image/jpeg*)              EXT=jpg ;;
        image/svg*)               EXT=svg ;;
        application/pdf*)         EXT=pdf ;;
        application/octet-stream*) EXT=bin ;;
        ""|*)                     EXT=bin ;;
    esac
    BODY_FINAL=$OUT_DIR/body.$EXT
    cp "$BODY_TMP" "$BODY_FINAL"

    IDENTITY=$(awk '
        BEGIN { IGNORECASE=1 }
        /^Content-Type:|^Content-Length:|^Server:|^X-Powered-By:|^ETag:|^Cache-Control:|^Last-Modified:|^Set-Cookie:/ {
            gsub(/\r/, ""); print "  " $0
        }
    ' "$HEADERS_TMP")
    SEC=$(awk '
        BEGIN { IGNORECASE=1 }
        /^Strict-Transport-Security:|^Content-Security-Policy:|^X-Frame-Options:|^X-Content-Type-Options:|^Referrer-Policy:|^Permissions-Policy:|^Cross-Origin-Opener-Policy:|^Cross-Origin-Embedder-Policy:/ {
            gsub(/\r/, ""); print "  OK    " $0
        }
    ' "$HEADERS_TMP")

    {
        printf '--- Dialogue: HTTP request → response ---\n'
        printf '  Timing:        DNS=%ss  TCP=%ss  TLS=%ss  TTFB=%ss  Total=%ss\n' \
               "$T_DNS" "$T_CONN" "$T_TLS" "$T_TTFB" "$T_TOTAL"
        printf '  Remote peer:   %s:%s\n' "$H_RIP" "$H_RPORT"
        printf '  HTTP code:     %s   HTTP ver: %s   Redirects: %s\n' "$H_CODE" "$H_VER" "$H_REDIR"
        printf '  Final URL:     %s\n' "$H_URL"
        printf '  Body size:     %s bytes  →  %s\n' "$H_SIZE" "$BODY_FINAL"
        printf '\n--- Response identity (MIME / fingerprint) ---\n'
        [ -n "$IDENTITY" ] && printf '%s\n' "$IDENTITY" || printf '  (none captured)\n'
        printf '\n--- Security headers ---\n'
        [ -n "$SEC" ] && printf '%s\n' "$SEC" || printf '  (none present)\n'
    } > "$TMP/messaging.out"
}

ml_server_first_text() {
    # Args: $1=label, $2='tls'|'raw', $3=STARTTLS_MODE (or "")
    # Stdin: client commands (sent after the server greeting)
    LABEL=$1; CHAN=$2; ST=$3
    CLIENT_CMDS=$(cat)
    # Section markers do NOT start with '< ' so the greeting extraction below
    # cleanly picks up actual server bytes, not transcript headers.
    {
        printf '=== Messaging Layer: %s ===\n' "$LABEL"
        printf 'Pattern: server-first (server sends banner, we respond)\n'
        printf 'Channel: %s%s\n\n' "$CHAN" "${ST:+ (starttls=$ST)}"
        printf '## CLIENT PROBE (sent after greeting)\n'
        if [ -n "$CLIENT_CMDS" ]; then
            printf '%s\n' "$CLIENT_CMDS" | sed 's/^/> /'
        else
            printf '## (no client command — banner-only probe)\n'
        fi
        printf '\n## SERVER TRANSCRIPT (lines prefixed `< `)\n'
    } > "$DIALOGUE"
    {
        printf '%s\n' "$CLIENT_CMDS"
        sleep 1
    } | ml_pipe "$CHAN" "$ST" \
        | sed 's/^/< /' >> "$DIALOGUE" 2>&1

    # First poke = first non-empty line of actual server bytes (`< ` prefix)
    FIRST=$(grep '^< .' "$DIALOGUE" | head -1 | sed 's/^< //' | head -c 200)
    LINES=$(grep -c '^< .' "$DIALOGUE")
    case "$LABEL" in
        SMTP*) SCHEMA='^220 ' ;;
        IMAP*) SCHEMA='^\* OK' ;;
        POP3*) SCHEMA='^\+OK'  ;;
        SSH)   SCHEMA='^SSH-'  ;;
        FTP)   SCHEMA='^220 '  ;;
        *)     SCHEMA=''       ;;
    esac
    {
        printf '--- First poke (server greeting) ---\n'
        printf '  %s\n' "${FIRST:-(no greeting received within timeout)}"
        printf '\n--- Second poke (our client commands) ---\n'
        if [ -n "$CLIENT_CMDS" ]; then
            printf '%s\n' "$CLIENT_CMDS" | sed 's/^/  > /'
        else
            printf '  (banner-only — no client poke sent)\n'
        fi
        printf '\n--- Server reply summary ---\n'
        printf '  %s line(s) captured  →  %s\n' "${LINES:-0}" "$DIALOGUE"
        if [ -n "$SCHEMA" ]; then
            if printf '%s' "$FIRST" | grep -qE "$SCHEMA"; then
                printf '\n--- Schema check ---\n  PASS — greeting matches %s pattern (%s)\n' "$LABEL" "$SCHEMA"
            else
                printf '\n--- Schema check ---\n  FAIL — greeting does NOT match %s pattern (%s) — possible protocol mismatch\n' "$LABEL" "$SCHEMA"
            fi
        fi
    } > "$TMP/messaging.out"
}

ml_smtp_cleartext() { printf 'EHLO probe.local\r\nQUIT\r\n' | ml_server_first_text "SMTP" "raw" ""; }
ml_smtp_starttls()  { printf 'EHLO probe.local\r\nQUIT\r\n' | ml_server_first_text "SMTP+STARTTLS" "tls" "smtp"; }
ml_smtps()          { printf 'EHLO probe.local\r\nQUIT\r\n' | ml_server_first_text "SMTPS" "tls" ""; }
ml_imap_cleartext() { printf 'a01 CAPABILITY\r\na02 LOGOUT\r\n' | ml_server_first_text "IMAP" "raw" ""; }
ml_imaps()          { printf 'a01 CAPABILITY\r\na02 LOGOUT\r\n' | ml_server_first_text "IMAPS" "tls" ""; }
ml_pop3_cleartext() { printf 'CAPA\r\nQUIT\r\n' | ml_server_first_text "POP3" "raw" ""; }
ml_pop3s()          { printf 'CAPA\r\nQUIT\r\n' | ml_server_first_text "POP3S" "tls" ""; }
ml_ssh()            { printf '' | ml_server_first_text "SSH" "raw" ""; }
ml_ftp()            { printf 'QUIT\r\n' | ml_server_first_text "FTP" "raw" ""; }

ml_tcp_auto() {
    {
        printf '=== Messaging Layer: TCP-raw (autodetect) ===\n'
        printf 'Connecting %s:%s, listening 3s for server-first greeting...\n\n' "$HOST" "$PORT"
    } > "$DIALOGUE"
    PEEK=$( (printf ''; sleep 3) | nc -w 4 "$HOST" "$PORT" 2>&1 | head -c 256)
    if [ -n "$PEEK" ]; then
        { printf '< === Server greeted first (server-first) ===\n'
          printf '%s\n' "$PEEK" | sed 's/^/< /'; } >> "$DIALOGUE"
        FIRST=$(printf '%s' "$PEEK" | head -1 | head -c 200)
        SPEAKER=server
    else
        { printf '> === Server silent 3s — sending HTTP-style client-first probe ===\n'
          printf '> GET / HTTP/1.0\n>\n'; } >> "$DIALOGUE"
        RESP=$( (printf 'GET / HTTP/1.0\r\n\r\n'; sleep 2) | nc -w 5 "$HOST" "$PORT" 2>&1 | head -c 1024)
        { printf '\n< === Server response to HTTP probe ===\n'
          printf '%s\n' "$RESP" | sed 's/^/< /'; } >> "$DIALOGUE"
        FIRST=$(printf '%s' "$RESP" | head -1 | head -c 200)
        SPEAKER=client
    fi
    {
        printf '--- TCP autodetect result ---\n'
        printf '  First speaker:  %s\n' "$SPEAKER"
        printf '  First bytes:    %s\n' "${FIRST:-(none)}"
        printf '  Full transcript → %s\n' "$DIALOGUE"
    } > "$TMP/messaging.out"
}

worker_messaging() {
    # Pre-flight: if TCP port isn't open, skip the dialogue entirely.
    # Without this guard, openssl s_client on a closed port can hang ~2 min
    # waiting for the kernel TCP retry budget to drain.
    if [ "$HAVE_NC" = 1 ] && ! nc -z -w 4 "$HOST" "$PORT" 2>/dev/null; then
        {
            printf '=== Messaging Layer: %s ===\n' "$PROTO_LABEL"
            printf 'TCP %s:%s is CLOSED or FILTERED — skipping protocol dialogue.\n' "$HOST" "$PORT"
            printf '(Pre-flight nc -z -w 4 returned non-zero; not running openssl/curl/banner probe.)\n'
        } > "$DIALOGUE"
        {
            printf '--- Pre-flight TCP check ---\n'
            printf '  %s:%s  state: CLOSED or FILTERED\n' "$HOST" "$PORT"
            printf '  Dialogue skipped (would have hung on socket retry timeout).\n'
            printf '  Full transcript → %s\n' "$DIALOGUE"
        } > "$TMP/messaging.out"
        return 0
    fi
    case "$SCHEME" in
        http|https) ml_http ;;
        smtp)       ml_smtp_cleartext ;;
        submission) ml_smtp_starttls ;;
        smtps)      ml_smtps ;;
        imap)       ml_imap_cleartext ;;
        imaps)      ml_imaps ;;
        pop3)       ml_pop3_cleartext ;;
        pop3s)      ml_pop3s ;;
        ssh)        ml_ssh ;;
        ftp)        ml_ftp ;;
        tcp)        ml_tcp_auto ;;
    esac
}

###############################################################################
# Caddy L4 footprint synthesis
###############################################################################

worker_caddy_l4() {
    OUT=$TMP/caddy_l4.out
    {
        if [ "$USE_TLS" = 0 ]; then
            printf '  (cleartext scheme — N/A)\n'
            return 0
        fi
        if [ ! -s "$OPENSSL_LOG" ]; then
            printf '  TLS expected but handshake failed at this port — cannot fingerprint.\n'
            printf '  Likely causes: port closed/filtered, SNI rejected, ISP blocks the port outbound.\n'
            return 0
        fi
        FP=$(openssl x509 -in "$OPENSSL_LOG" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//')
        SAN=$(openssl x509 -in "$OPENSSL_LOG" -noout -ext subjectAltName 2>/dev/null | awk '/DNS:/ {print; exit}')
        printf 'TLS cert sha256:  %s\n' "${FP:-?}"
        printf 'SAN line:         %s\n' "${SAN:-?}"
        printf '\nHow to confirm Caddy L4 multi-port frontend:\n'
        printf '  1. server-scanning.sh %s --banner\n' "$HOST"
        printf '  2. For each TLS-bearing port (443, 465, 587, 993, 995):\n'
        printf '       url-triage.sh <scheme>://%s:<port>\n' "$HOST"
        printf '  3. Compare the "TLS cert sha256" line across runs.\n'
        printf '     Same fp  → shared Caddy L4 termination (one frontend).\n'
        printf '     Diff fps → separate listeners per port.\n'
    } > "$OUT" 2>&1
}

###############################################################################
# Launch workers in parallel
###############################################################################

START_TS=$(date +%s)
STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

worker_l3_dns   & PID_DNS=$!
worker_l3_whois & PID_WHOIS=$!
worker_l3_path  & PID_PATH=$!
worker_l4_port  & PID_L4=$!
worker_l56_tls  & PID_TLS=$!
worker_l7_app   & PID_L7=$!
worker_messaging & PID_MSG=$!

wait "$PID_DNS"   2>/dev/null
wait "$PID_WHOIS" 2>/dev/null
wait "$PID_PATH"  2>/dev/null
wait "$PID_L4"    2>/dev/null
wait "$PID_TLS"   2>/dev/null
wait "$PID_L7"    2>/dev/null
wait "$PID_MSG"   2>/dev/null

worker_caddy_l4

END_TS=$(date +%s)
FINISHED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ELAPSED=$(( END_TS - START_TS ))

###############################################################################
# Assemble report.json
###############################################################################

read_or_empty() { [ -s "$1" ] && cat "$1" || printf ''; }

L3_DNS=$(read_or_empty "$TMP/l3-dns.out")
L3_WHOIS=$(read_or_empty "$TMP/l3-whois.out")
L3_PATH=$(read_or_empty "$TMP/l3-path.out")
L4_PORT=$(read_or_empty "$TMP/l4-port.out")
L5=$(read_or_empty "$TMP/l5-session.out")
L6=$(read_or_empty "$TMP/l6-presentation.out")
L7=$(read_or_empty "$TMP/l7-app.out")
MSG=$(read_or_empty "$TMP/messaging.out")
CADDY=$(read_or_empty "$TMP/caddy_l4.out")

BODY_FILE=""
for f in "$OUT_DIR"/body.*; do [ -f "$f" ] && BODY_FILE=$(basename "$f"); done

# Touch the two transcript files so --rawfile is safe even when a worker
# skipped writing them (e.g. cleartext scheme has no openssl-handshake).
: > "${DIALOGUE}.ensure" 2>/dev/null; rm -f "${DIALOGUE}.ensure"
[ -f "$DIALOGUE" ]    || : > "$DIALOGUE"
[ -f "$OPENSSL_LOG" ] || : > "$OPENSSL_LOG"

jq -n \
    --arg input "$INPUT" --arg scheme "$SCHEME" --arg host "$HOST" \
    --argjson port "$PORT" --arg path "$PATH_PART" \
    --argjson use_tls "$USE_TLS" --arg starttls "${STARTTLS_MODE:-}" \
    --arg first_speaker "$FIRST_SPEAKER" --arg proto_label "$PROTO_LABEL" \
    --argjson is_ip "$IS_IP" --arg apex "$APEX" \
    --arg started_at "$STARTED_AT" --arg finished_at "$FINISHED_AT" \
    --argjson elapsed "$ELAPSED" \
    --arg l3_dns "$L3_DNS"     --arg l3_whois "$L3_WHOIS" \
    --arg l3_path "$L3_PATH"   --arg l4_port "$L4_PORT" \
    --arg l5 "$L5"             --arg l6 "$L6" \
    --arg l7 "$L7"             --arg msg "$MSG" \
    --arg caddy "$CADDY" \
    --arg body_file "$BODY_FILE" \
    --rawfile dialogue_raw "$DIALOGUE" \
    --rawfile openssl_raw  "$OPENSSL_LOG" \
    '
    def lines(t): t | rtrimstr("\n") | split("\n");
    def sec($label; $color; $text): { label: $label, color: $color, lines: lines($text) };
    # Split the messaging-layer transcript into client_pokes / server_replies
    # based on the convention used by ml_server_first_text / ml_http
    # (lines prefixed `> ` are client→server, `< ` are server→client).
    ($dialogue_raw | rtrimstr("\n") | split("\n")) as $dlines |
    {
      meta: {
        input: $input, scheme: $scheme, host: $host, port: $port, path: $path,
        apex: $apex, is_ip: ($is_ip == 1), use_tls: ($use_tls == 1),
        starttls: $starttls, first_speaker: $first_speaker,
        proto_label: $proto_label,
        started_at: $started_at, finished_at: $finished_at,
        elapsed_seconds: $elapsed
      },
      layers: {
        l3_network:        { dns:   sec("L3 · DNS";          "cyan";    $l3_dns),
                             whois: sec("L3 · WHOIS/ASN/PTR";"cyan";    $l3_whois),
                             path:  sec("L3 · PATH";          "cyan";    $l3_path) },
        l4_transport:      sec("L4 · Transport (single-port)"; "blue";    $l4_port),
        l5_session:        sec("L5 · Session (TLS handshake)"; "magenta"; $l5),
        l6_presentation:   sec("L6 · Presentation (cert)";     "magenta"; $l6),
        l7_application:    sec("L7 · Application protocol";    "green";   $l7),
        messaging:         sec("Messaging Layer (dialogue)";   "yellow";  $msg),
        caddy_l4_footprint: sec("Caddy L4 footprint";          "red";     $caddy)
      },
      transcripts: {
        messaging_dialogue: {
          label:          "Messaging Layer raw transcript",
          line_count:     ($dlines | length),
          lines:          $dlines,
          client_pokes:   ($dlines | map(select(startswith("> ")) | ltrimstr("> "))),
          server_replies: ($dlines | map(select(startswith("< ")) | ltrimstr("< ")))
        },
        tls_handshake: (
          if $use_tls == 1 then {
            label:      "OpenSSL s_client handshake transcript",
            line_count: ($openssl_raw | rtrimstr("\n") | split("\n") | length),
            lines:      ($openssl_raw | rtrimstr("\n") | split("\n"))
          } else null end
        )
      },
      artifacts: {
        report: "report.json",
        body:   ( if $body_file != "" then $body_file else null end )
      }
    }
    ' > "$REPORT_JSON"

# Transcripts are now embedded in report.json — remove the sibling .txt files.
rm -f "$DIALOGUE" "$OPENSSL_LOG"

###############################################################################
# Render console output FROM the JSON
###############################################################################

color_of() {
    case "$1" in
        cyan)    printf '%s' "$C_CYAN" ;;
        blue)    printf '%s' "$C_BLUE" ;;
        green)   printf '%s' "$C_GREEN" ;;
        magenta) printf '%s' "$C_MAGENTA" ;;
        yellow)  printf '%s' "$C_YELLOW" ;;
        red)     printf '%s' "$C_RED" ;;
        *)       printf '' ;;
    esac
}

META=$(jq -r '.meta | "\(.host)\t\(.port)\t\(.scheme)\t\(.proto_label)\t\(.first_speaker)\t\(.use_tls)\t\(.started_at)\t\(.elapsed_seconds)"' "$REPORT_JSON")
M_HOST=$(printf '%s'   "$META" | awk -F'\t' '{print $1}')
M_PORT=$(printf '%s'   "$META" | awk -F'\t' '{print $2}')
M_SCHEME=$(printf '%s' "$META" | awk -F'\t' '{print $3}')
M_PROTO=$(printf '%s'  "$META" | awk -F'\t' '{print $4}')
M_SPK=$(printf '%s'    "$META" | awk -F'\t' '{print $5}')
M_TLS=$(printf '%s'    "$META" | awk -F'\t' '{print $6}')
M_START=$(printf '%s'  "$META" | awk -F'\t' '{print $7}')
M_EL=$(printf '%s'     "$META" | awk -F'\t' '{print $8}')

printf '%s== url-triage(%s://%s:%s)  proto=%s  speaker=%s  TLS=%s ==%s\n' \
       "$C_BOLD" "$M_SCHEME" "$M_HOST" "$M_PORT" "$M_PROTO" "$M_SPK" "$M_TLS" "$C_OFF"
printf '%sStarted %s  ·  elapsed %ss  ·  artifacts: %s%s\n' \
       "$C_DIM" "$M_START" "$M_EL" "$OUT_DIR" "$C_OFF"

print_sec() {
    JQ_PATH=$1
    LABEL=$(jq -r "$JQ_PATH.label // \"\"" "$REPORT_JSON")
    COLOR_NAME=$(jq -r "$JQ_PATH.color // \"\"" "$REPORT_JSON")
    [ -z "$LABEL" ] && return 0
    COLOR=$(color_of "$COLOR_NAME")
    printf '\n%s=== %s ===%s\n' "$COLOR" "$LABEL" "$C_OFF"
    jq -r "$JQ_PATH.lines as \$L | if (\$L|length)==0 then \"  (no output)\" else \$L[] end" "$REPORT_JSON"
}

print_sec ".layers.l3_network.dns"
print_sec ".layers.l3_network.whois"
print_sec ".layers.l3_network.path"
print_sec ".layers.l4_transport"
print_sec ".layers.l5_session"
print_sec ".layers.l6_presentation"
print_sec ".layers.l7_application"
print_sec ".layers.messaging"
print_sec ".layers.caddy_l4_footprint"

printf '\n%s== triage done in %ss  ·  %s ==%s\n' "$C_BOLD" "$M_EL" "$REPORT_JSON" "$C_OFF"
jq -r '.artifacts | to_entries[] | "  " + .key + ": " + (.value // "(none)")' "$REPORT_JSON"
