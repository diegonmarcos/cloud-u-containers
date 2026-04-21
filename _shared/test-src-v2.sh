#!/bin/sh
# ══════════════════════════════════════════════════════════════════
# test-src-v2.sh — validate a service's src/ against canonical v2
#
# Usage: test-src-v2.sh <path-to-src>
#
# Enforces the "Canonical src/ layout v2" spec:
#   - required: flake.nix, build.json symlink
#   - allowed:  compose.nix, templates/*.tpl, secrets.yaml, sensitive
#               materials, docs/, data JSONs (service's own declarative
#               inputs), Type A native sources under src/code/,
#               build-<ctr>.json symlinks into 2_configs/dist/
#   - banned:   Dockerfile (engine generates),
#               manifest.json symlinks (dashboard concern),
#               cloud-data-*.json symlinks (engine collects),
#               stale markers (.rebuild-trigger),
#               superseded sources (*.py alongside main.rs)
#               source files at src/ root (must live in src/code/)
# ══════════════════════════════════════════════════════════════════
set -eu

SRC="${1:-}"
[ -n "$SRC" ] || { echo "usage: $0 <src-path>" >&2; exit 2; }
[ -d "$SRC" ] || { echo "not a directory: $SRC" >&2; exit 2; }

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }

printf '\n═══ src/ v2 validator ═══\n'
printf 'target: %s\n\n' "$SRC"

# ── required files ───────────────────────────────────────────────
printf '── required ──\n'
[ -f "$SRC/flake.nix" ]     && pass "flake.nix"       || fail "flake.nix MISSING"
[ -L "$SRC/build.json" ]    && pass "build.json (symlink)" \
  || fail "build.json MISSING or not a symlink to ../build.json"

# ── banned: Dockerfile at src/ root ──────────────────────────────
printf '\n── banned: engine-generated artifacts ──\n'
if [ -f "$SRC/Dockerfile" ]; then
    fail "Dockerfile present (engine emits dist/code/<arch>/Dockerfile — remove this)"
else
    pass "no loose Dockerfile"
fi

# ── banned: dashboard manifest.json ──────────────────────────────
if [ -e "$SRC/manifest.json" ]; then
    fail "manifest.json present (dashboard concern, lives in 2_configs/dist/)"
else
    pass "no manifest.json"
fi

# ── banned: scattered cloud-data-*.json symlinks ─────────────────
printf '\n── banned: scattered cloud-data symlinks ──\n'
cd_count=$(find "$SRC" -maxdepth 1 \( -name 'cloud-data-*.json' -o -name '_cloud-data-*.json' \) 2>/dev/null | wc -l)
if [ "$cd_count" -gt 0 ]; then
    fail "$cd_count cloud-data-*.json symlinks in src/ (engine reads 2_configs/dist/ directly)"
else
    pass "no cloud-data-*.json pollution"
fi

# ── banned: stale markers ────────────────────────────────────────
printf '\n── banned: stale markers ──\n'
for stale in .rebuild-trigger; do
    if [ -e "$SRC/$stale" ]; then
        fail "stale marker $stale present"
    else
        pass "no $stale"
    fi
done

# ── banned: source files at src/ root (must be in src/code/) ────
printf '\n── banned: source files at src/ root (must be in src/code/) ──\n'
found_root_source=0
for pat in '*.rs' 'Cargo.toml' 'Cargo.lock' '*.go' 'go.mod' 'go.sum' '*.py'; do
    for f in "$SRC"/$pat; do
        [ -e "$f" ] || continue
        fail "$(basename "$f") at src/ root — move into src/code/"
        found_root_source=1
    done
done
if [ -d "$SRC/code" ] && [ "$found_root_source" -eq 0 ]; then
    pass "source files properly scoped under src/code/"
fi

# ── allowed: code/ hygiene ───────────────────────────────────────
if [ -d "$SRC/code" ]; then
    printf '\n── code/ contents ──\n'
    for f in "$SRC/code"/*; do
        [ -e "$f" ] || continue
        pass "code/$(basename "$f")"
    done
fi

# ── allowed: templates/ must hold only .tpl files ────────────────
if [ -d "$SRC/templates" ]; then
    printf '\n── templates/ hygiene ──\n'
    for f in "$SRC/templates"/*; do
        [ -e "$f" ] || continue
        case "$(basename "$f")" in
            *.tpl) pass "templates/$(basename "$f")" ;;
            *) fail "templates/$(basename "$f") — only *.tpl allowed" ;;
        esac
    done
fi

# ── Summary ──────────────────────────────────────────────────────
printf '\n═══ %d pass / %d fail ═══\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
