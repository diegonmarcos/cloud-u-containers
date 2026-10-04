#!/bin/sh
# ══════════════════════════════════════════════════════════════════
# test-dist-v2.sh — validate a service's dist/ against layout v2
#
# Usage:
#   test-dist-v2.sh <path-to-dist>
#
# Exit 0 if conformant, non-zero otherwise.
# ══════════════════════════════════════════════════════════════════
set -eu

DIST="${1:-}"
[ -n "$DIST" ] || { echo "usage: $0 <dist-path>" >&2; exit 2; }
[ -d "$DIST" ] || { echo "not a directory: $DIST" >&2; exit 2; }

PASS=0
FAIL=0
pass() { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }

check_dir()  { [ -d "$DIST/$1" ] && pass "dir  $1/" || fail "dir  $1/ MISSING"; }
check_file() { [ -f "$DIST/$1" ] && pass "file $1"  || fail "file $1 MISSING"; }

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || { echo "missing dep: $1" >&2; exit 2; }
}
need_cmd jq
need_cmd yq

printf '\n═══ dist v2 validator ═══\n'
printf 'target: %s\n\n' "$DIST"

# ── 1. Canonical top-level skeleton ───────────────────────────────
# v2: code/, configs/, compose/, assets/ only.
# data/ and top-level hooks/ MUST NOT appear.
printf '── skeleton ──\n'
for d in code configs compose assets; do
    check_dir "$d"
done
for forbidden_top in data hooks; do
    if [ -d "$DIST/$forbidden_top" ]; then
        fail "top-level $forbidden_top/ present (hooks → assets/hooks, no data bundling)"
    else
        pass "no top-level $forbidden_top/ (correct)"
    fi
done

# ── 2. manifest.json ──────────────────────────────────────────────
printf '\n── manifest.json ──\n'
check_file "manifest.json"
if [ -f "$DIST/manifest.json" ]; then
    if jq -e . "$DIST/manifest.json" >/dev/null 2>&1; then
        pass "manifest.json parses as JSON"
    else
        fail "manifest.json is not valid JSON"
    fi
    for field in service type archs images upstream_ref include_cloud_data has_hooks _meta _banner; do
        if jq -e "has(\"$field\")" "$DIST/manifest.json" >/dev/null 2>&1; then
            pass "manifest.$field present"
        else
            fail "manifest.$field MISSING"
        fi
    done
    lv=$(jq -r '._meta.layout_version // empty' "$DIST/manifest.json")
    [ "$lv" = "2" ] && pass "manifest._meta.layout_version=2" \
                    || fail "manifest._meta.layout_version='$lv' (expected 2)"
    svc_type=$(jq -r '.type // empty' "$DIST/manifest.json")
    case "$svc_type" in
        own-code|wrap-image) pass "manifest.type='$svc_type'" ;;
        *) fail "manifest.type='$svc_type' (expected own-code|wrap-image)" ;;
    esac
fi

# ── 3. code/<arch>/ — amd64 + arm64 slots always present ──────────
printf '\n── code/ (multi-arch always present) ──\n'
for arch in amd64 arm64; do
    if [ -d "$DIST/code/$arch" ]; then
        if [ -f "$DIST/code/$arch/Dockerfile" ]; then
            pass "code/$arch/Dockerfile (declared arch)"
        elif [ -f "$DIST/code/$arch/.skip" ]; then
            pass "code/$arch/.skip (non-declared arch)"
        else
            fail "code/$arch/ has neither Dockerfile nor .skip"
        fi
    else
        fail "code/$arch/ MISSING"
    fi
done

# ── 4. configs/ ──────────────────────────────────────────────────
printf '\n── configs/ ──\n'
check_file "configs/Dockerfile"
if [ -f "$DIST/configs/Dockerfile" ]; then
    if grep -q '^FROM scratch' "$DIST/configs/Dockerfile"; then
        pass "configs/Dockerfile is FROM scratch"
    else
        fail "configs/Dockerfile not FROM scratch"
    fi
fi

# ── 5. compose/docker-compose.yml ────────────────────────────────
printf '\n── compose/ ──\n'
check_file "compose/docker-compose.yml"

# ── 5b. Every service inherits fleet-wide compose defaults ───────
SHARED="$(cd "$(dirname "$0")" && pwd)"
DEFAULTS_JSON="$SHARED/compose-defaults.json"
COMPOSE="$DIST/compose/docker-compose.yml"
if [ -f "$DEFAULTS_JSON" ] && [ -f "$COMPOSE" ]; then
    printf '\n── compose defaults (merged by engine) ──\n'
    fields=$(jq -r '.defaults | keys[]' "$DEFAULTS_JSON")
    svcs=$(yq -r '.services | keys | .[]' "$COMPOSE" 2>/dev/null || true)
    for svc in $svcs; do
        for field in $fields; do
            val=$(yq -r ".services.\"$svc\".\"$field\" // \"MISSING\"" "$COMPOSE" 2>/dev/null)
            if [ "$val" = "MISSING" ] || [ -z "$val" ] || [ "$val" = "null" ]; then
                fail "services.$svc.$field MISSING (engine should merge default)"
            else
                pass "services.$svc.$field present"
            fi
        done
    done

    # ── 5c. Specific value checks for security-critical defaults ────
    # init: true (tini PID-1 reaper — fixes zombie-class bugs like Dagu 2026-04-29)
    # logging.options.max-file: 7 (≈ 7 days retention for low-traffic containers)
    printf '\n── compose defaults (specific values) ──\n'
    for svc in $svcs; do
        # Containers using their own init system explicitly override init:false;
        # the test accepts either true OR explicit false (presence is what matters).
        init_val=$(yq -r ".services.\"$svc\".init // \"MISSING\"" "$COMPOSE" 2>/dev/null)
        case "$init_val" in
            true|false) pass "services.$svc.init = $init_val (declared)" ;;
            MISSING|null|"") fail "services.$svc.init MISSING (engine should merge default true)" ;;
            *)          fail "services.$svc.init unexpected value: $init_val" ;;
        esac

        max_file=$(yq -r ".services.\"$svc\".logging.options.\"max-file\" // \"MISSING\"" "$COMPOSE" 2>/dev/null)
        if [ "$max_file" = "7" ] || [ "$max_file" = "MISSING" ] || [ "$max_file" = "null" ]; then
            [ "$max_file" = "7" ] && pass "services.$svc.logging.options.max-file = 7" \
                                  || fail "services.$svc.logging.options.max-file MISSING (engine should merge default 7)"
        else
            # Service explicitly overrode — accept any non-default value but log it
            pass "services.$svc.logging.options.max-file = $max_file (per-service override)"
        fi
    done
fi

# ── 6. Forbidden folders must NOT be committed ───────────────────
printf '\n── forbidden (must be gitignored) ──\n'
for forbidden in secrets sensitive .build; do
    if [ -d "$DIST/$forbidden" ]; then
        entries=$(find "$DIST/$forbidden" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
        if [ "$entries" -eq 0 ]; then
            pass "$forbidden/ exists but empty"
        else
            fail "$forbidden/ has $entries entries (should be gitignored, engine does not populate)"
        fi
    else
        pass "$forbidden/ absent (good)"
    fi
done

# ── 6b. Banner marker on every generated file ────────────────────
printf '\n── banner injection (AUTO-GENERATED marker) ──\n'
BANNER_MARK="AUTO-GENERATED by _shared/engine.nix"
for f in \
    "$DIST/compose/docker-compose.yml" \
    "$DIST/configs/Dockerfile" \
    "$DIST/code/amd64/Dockerfile" \
    "$DIST/code/arm64/Dockerfile"; do
    [ -f "$f" ] || continue
    rel="${f#$DIST/}"
    if grep -qF "$BANNER_MARK" "$f"; then
        pass "banner in $rel"
    else
        fail "banner MISSING in $rel"
    fi
done
if [ -d "$DIST/configs" ]; then
    for f in "$DIST/configs"/*; do
        [ -f "$f" ] || continue
        case "$(basename "$f")" in
            Dockerfile) continue ;;
        esac
        rel="${f#$DIST/}"
        if grep -qF "$BANNER_MARK" "$f"; then
            pass "banner in $rel"
        else
            fail "banner MISSING in $rel"
        fi
    done
fi
if [ -f "$DIST/manifest.json" ]; then
    if jq -e '._banner | arrays | length > 0' "$DIST/manifest.json" >/dev/null 2>&1; then
        pass "manifest._banner array present"
    else
        fail "manifest._banner MISSING or empty"
    fi
fi

# ── 6c. manifest.has_hooks matches assets/hooks/ presence ────────
if [ -f "$DIST/manifest.json" ]; then
    declared=$(jq -r '.has_hooks' "$DIST/manifest.json")
    present="false"
    [ -d "$DIST/assets/hooks" ] && present="true"
    if [ "$declared" = "$present" ]; then
        pass "manifest.has_hooks=$declared matches assets/hooks/ presence"
    else
        fail "manifest.has_hooks=$declared but assets/hooks/ present=$present"
    fi
fi

# ── 7. Cross-check manifest.archs ↔ code/ slots ──────────────────
if [ -f "$DIST/manifest.json" ]; then
    printf '\n── manifest.archs vs code/ ──\n'
    for arch in $(jq -r '.archs[]?' "$DIST/manifest.json" 2>/dev/null); do
        if [ -f "$DIST/code/$arch/Dockerfile" ]; then
            pass "archs['$arch'] has code/$arch/Dockerfile"
        else
            fail "archs['$arch'] declared but code/$arch/Dockerfile missing"
        fi
    done
fi

# ── Summary ───────────────────────────────────────────────────────
printf '\n═══ %d pass / %d fail ═══\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
