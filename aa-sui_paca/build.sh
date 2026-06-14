#!/bin/sh
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Container Engine — dispatcher + config                          ║
# ║                                                                  ║
# ║ Symlinked as build.sh in each service directory.                ║
# ║ All behavior driven by build.json — zero hardcoded names.       ║
# ║ Steps are sourced from cloud-ship-container-step-*.sh files.    ║
# ╚══════════════════════════════════════════════════════════════════╝
set -e

# Auto-confirm guardrail prompts (BLOCKED tier is never bypassed)
export BUILDSH_GUARDRAIL=1

# Shared node_modules — ESM resolution needs NODE_PATH
export NODE_PATH="${NODE_PATH:-$HOME/.node_modules/node_modules}"

SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_NAME="$(basename "$SERVICE_DIR" | sed 's/^[a-z]*-[a-z]*_//')"
SRC_DIR="$SERVICE_DIR/src"
DIST_DIR="$SERVICE_DIR/dist"
CONFIG="$SERVICE_DIR/build.json"

# ── Config reader (node primary, python3 fallback) ────────────────────
get_config() {
    [ ! -f "$CONFIG" ] && return 0
    if command -v node >/dev/null 2>&1; then
        node -e "const c=require('$CONFIG'); const v='$1'.split('.').reduce((o,k)=>o&&o[k],c); process.stdout.write(String(v||''))"
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c "import json; c=json.load(open('$CONFIG')); v=$( echo "'$1'.split('.')" | sed "s/'/\"/g" ); r=c; exec('for k in v: r=r.get(k,{})'); print(r if isinstance(r,str) else '',end='')"
    fi
}

# JSON array reader → newline-separated values
get_config_array() {
    [ ! -f "$CONFIG" ] && return 0
    if command -v node >/dev/null 2>&1; then
        node -e "const c=require('$CONFIG'); const v='$1'.split('.').reduce((o,k)=>o&&o[k],c); if(Array.isArray(v)) v.forEach(i=>console.log(i))"
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c "
import json; c=json.load(open('$CONFIG'))
v = c
for k in '$1'.split('.'):
    v = v.get(k, {}) if isinstance(v, dict) else {}
if isinstance(v, list):
    for i in v: print(i)
"
    fi
}

# JSON object reader for lifecycle actions → JSON lines
get_lifecycle() {
    [ ! -f "$CONFIG" ] && return 0
    if command -v node >/dev/null 2>&1; then
        node -e "
const c=require('$CONFIG');
const v=(c.lifecycle||{})['$1'];
if(Array.isArray(v)) v.forEach(a=>console.log(JSON.stringify(a)));
"
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c "
import json; c=json.load(open('$CONFIG'))
for a in c.get('lifecycle',{}).get('$1',[]):
    print(json.dumps(a))
"
    fi
}

# ── Load config ───────────────────────────────────────────────────────
if [ -f "$CONFIG" ]; then
    DEPLOY_HOST="$(get_config deploy.host)"
    DEPLOY_PATH="$(get_config deploy.remote_path)"
    DOCKER_REGISTRY="$(get_config docker.registry)"
    DOCKER_IMAGE="$(get_config docker.image)"
    DOCKER_FILE="$(get_config docker.dockerfile)"
    DOCKER_BINARY="$(get_config docker.binary)"
    DOCKER_BINARY_NAME="$(get_config docker.binary_name)"
    DOCKER_PLATFORM="$(get_config docker.platform)"
    DOCKER_ARCH="$(get_config docker.arch)"
    # Backgrounded sub-shells (step_configs_push &, step_docker &) need these
    # in their environment. Without export, ${DOCKER_ARCH:-} in the subshell
    # evaluates to empty → configs image gets built for the GHA runner's
    # arch (amd64) instead of the target VM's arch (arm64 for oci-apps)
    # → "exec format error" when the VM pulls + runs it on deploy.
    export DOCKER_ARCH DOCKER_REGISTRY DOCKER_IMAGE DOCKER_PLATFORM SERVICE_NAME DIST_DIR COMPOSE_FILE SERVICE_DIR DEPLOY_HOST DEPLOY_PATH
    SEQUENTIAL_RESTART="$(get_config deploy.sequential_restart)"
    COMPOSE_FLAGS="$(get_config deploy.compose_flags)"
    ESCAPE_DOLLARS="$(get_config secrets.escape_dollars)"
    JWKS_FILE="$(get_config secrets.jwks_file)"
    JWKS_DEST="$(get_config secrets.jwks_dest)"
    PRESERVE_SYMLINKS="$(get_config build.preserve_symlinks)"
    INCLUDE_CLOUD_DATA="$(get_config build.include_cloud_data)"
    COMPOSE_PRE_HOOK="$(get_config compose.pre_hook)"
    COMPOSE_POST_HOOK="$(get_config compose.post_hook)"
    COMPOSE_CUSTOM="$(get_config compose.custom)"
    WRANGLER_DEPLOY="$(get_config deploy.wrangler)"
    WRANGLER_SECRETS_PUSH="$(get_config deploy.wrangler_secrets)"
    WRANGLER_SECRET_DROP="$(get_config_array deploy.wrangler_secret_drop)"
    TERRAFORM_DEPLOY="$(get_config deploy.terraform)"
    TERRAFORM_TFVARS_TEMPLATE="$(get_config terraform.tfvars_template)"
    BUILD_COPY_ONLY="$(get_config build.copy_only)"
fi

# ── Profile system: CLOUD_PROFILE selects active topology ────────────
if [ -n "${CLOUD_PROFILE:-}" ]; then
    PROFILE_JSON="$SERVICE_DIR/../../build_${CLOUD_PROFILE}.json"
    if [ -f "$PROFILE_JSON" ]; then
        P_HOST=$(node -e "const f=require('$PROFILE_JSON');const s=(f.services||{})['$SERVICE_NAME'];process.stdout.write(s&&s.deploy&&s.deploy.host||'')")
        if [ -n "$P_HOST" ]; then
            DEPLOY_HOST="$P_HOST"
            FORCE_DEPLOY=1
        else
            log "PROFILE[$CLOUD_PROFILE]: $SERVICE_NAME not in profile — skipping"
            exit 0
        fi
    fi
fi

# ── Layout version detection (v1 flat vs v2 categorised) ─────────────
# v2: layout_version == 2 → compose at dist/compose/docker-compose.yml
# v1: legacy flat layout    → compose at dist/docker-compose.yml
#
# Detection order — first match wins:
#   1) dist/manifest.json._meta.layout_version  (post-build truth)
#   2) src/flake.nix imports _shared/engine.nix (source-side signal — needed
#      for FIRST-EVER ship, when dist/ doesn't exist yet)
#   3) v1 fallback
#
# Idempotent function — call at engine init for standalone subcommands like
# `compose`, and again after step_build so the post-build truth wins.
detect_layout() {
    LAYOUT_V2=0
    COMPOSE_FILE="$DIST_DIR/docker-compose.yml"
    REMOTE_COMPOSE_REL="docker-compose.yml"

    # 1) Prefer dist/manifest.json (authoritative once built)
    if [ -f "$DIST_DIR/manifest.json" ] && command -v jq >/dev/null 2>&1; then
        # v1 manifest is an array; ._meta on array would crash under set -e.
        if jq -e 'type == "object"' "$DIST_DIR/manifest.json" >/dev/null 2>&1; then
            LV=$(jq -r '._meta.layout_version // 1' "$DIST_DIR/manifest.json" 2>/dev/null || echo 1)
            if [ "$LV" = "2" ]; then
                LAYOUT_V2=1
                COMPOSE_FILE="$DIST_DIR/compose/docker-compose.yml"
                REMOTE_COMPOSE_REL="compose/docker-compose.yml"
                export LAYOUT_V2 COMPOSE_FILE REMOTE_COMPOSE_REL
                return 0
            fi
        fi
    fi

    # 2) Fall back to src/flake.nix import — required for first-ever ship,
    #    where step_build has not yet produced dist/manifest.json. Every v2
    #    service imports `../../_shared/engine.nix`; v1 services do not.
    if [ -f "$SRC_DIR/flake.nix" ] && grep -q "_shared/engine.nix" "$SRC_DIR/flake.nix" 2>/dev/null; then
        LAYOUT_V2=1
        COMPOSE_FILE="$DIST_DIR/compose/docker-compose.yml"
        REMOTE_COMPOSE_REL="compose/docker-compose.yml"
    fi

    export LAYOUT_V2 COMPOSE_FILE REMOTE_COMPOSE_REL
}

detect_layout

# SSH multiplexing: one connection reused across all steps, kept alive 120s
SSH_OPTS="-o ControlMaster=auto -o ControlPath=/tmp/ssh-mux-%r@%h:%p -o ControlPersist=120 -o ServerAliveInterval=15 -o ServerAliveCountMax=8"

# SSH override hooks (used during VM cutover before DNS/alias points to new IP)
# SSH_HOST_OVERRIDE=<ip>          → -o HostName=<ip>
# SSH_KEY_OVERRIDE=<keyfile>      → -o IdentityFile=<keyfile> + IdentitiesOnly=yes
# SSH_USER_OVERRIDE=<user>        → -o User=<user>
if [ -n "${SSH_HOST_OVERRIDE:-}" ]; then
    SSH_OPTS="$SSH_OPTS -o HostName=${SSH_HOST_OVERRIDE}"
fi
if [ -n "${SSH_KEY_OVERRIDE:-}" ]; then
    SSH_OPTS="$SSH_OPTS -o IdentityFile=${SSH_KEY_OVERRIDE} -o IdentitiesOnly=yes"
fi
if [ -n "${SSH_USER_OVERRIDE:-}" ]; then
    SSH_OPTS="$SSH_OPTS -o User=${SSH_USER_OVERRIDE}"
fi
export SSH_OPTS
# Make rsync (called bare in some steps) honor SSH_OPTS via standard env var
export RSYNC_RSH="ssh $SSH_OPTS"

# Binary name for deploy payload (default: SERVICE_NAME-binary)
: "${DOCKER_BINARY_NAME:=${SERVICE_NAME}-binary}"

# Age key — use dotfile symlink set up by vault/build.sh setup system
: "${SOPS_AGE_KEY_FILE:=$HOME/.config/sops/age/keys.txt}"
export SOPS_AGE_KEY_FILE

log() { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$1"; }
log_warn() { printf "\033[0;33m[%s] WARNING: %s\033[0m\n" "$(date '+%H:%M:%S')" "$1"; }
log_error() { printf "\033[0;31m[%s] ERROR: %s\033[0m\n" "$(date '+%H:%M:%S')" "$1"; }

# ── SSH/rsync transport-blip retry helpers ────────────────────────────
# Single-shot SSH/rsync calls fail the entire ship pipeline when the
# runner host has transient SSH unreachability (WG flap, sshd MaxStartups
# bursts, brief sshd restarts). These helpers retry on transport-level
# failures only — real remote-command exit codes propagate unchanged.
#
# Tunables: $SSH_RETRY_N (default 3), $SSH_RETRY_BACKOFF (default 5).
# Set in callers from build-workflows.json (.probe.retries +
# .probe.backoff_seconds) for the full runners path; defaults work for
# the deploy/health steps that don't read the workflows registry.
ssh_with_retry() {
    _swr_n="${SSH_RETRY_N:-3}"
    _swr_bo="${SSH_RETRY_BACKOFF:-5}"
    _swr_attempt=0
    _swr_ec=0
    while [ "$_swr_attempt" -le "$_swr_n" ]; do
        ssh $SSH_OPTS "$@"
        _swr_ec=$?
        [ "$_swr_ec" -eq 0 ] && return 0
        # Exit 255 = SSH-level error (timeout / reset). Retry.
        # Other exit codes = remote command failed; do NOT retry.
        if [ "$_swr_ec" -ne 255 ]; then
            return "$_swr_ec"
        fi
        _swr_attempt=$((_swr_attempt + 1))
        if [ "$_swr_attempt" -le "$_swr_n" ]; then
            log_warn "ssh exit 255 attempt ${_swr_attempt}/${_swr_n} — retry in ${_swr_bo}s"
            sleep "$_swr_bo"
        fi
    done
    return "$_swr_ec"
}
rsync_with_retry() {
    _rwr_n="${SSH_RETRY_N:-3}"
    _rwr_bo="${SSH_RETRY_BACKOFF:-5}"
    _rwr_attempt=0
    _rwr_ec=0
    while [ "$_rwr_attempt" -le "$_rwr_n" ]; do
        rsync "$@"
        _rwr_ec=$?
        [ "$_rwr_ec" -eq 0 ] && return 0
        # rsync exit 12/30/255 = transport error (broken pipe, conn-reset,
        # ssh error). Retry. Other codes (perm, disk, partial) = real.
        case "$_rwr_ec" in
            12|30|255) ;;
            *) return "$_rwr_ec" ;;
        esac
        _rwr_attempt=$((_rwr_attempt + 1))
        if [ "$_rwr_attempt" -le "$_rwr_n" ]; then
            log_warn "rsync exit ${_rwr_ec} attempt ${_rwr_attempt}/${_rwr_n} — retry in ${_rwr_bo}s"
            sleep "$_rwr_bo"
        fi
    done
    return "$_rwr_ec"
}

# Global error handler: print step name on failure ONLY.
# Captures $? FIRST (any subsequent command resets it), then fires the
# error log only when actually exiting non-zero. Without the exit-status
# guard the trap fires on every successful exit too, with whatever $?
# happens to be (often 0 from a preceding subshell), producing the
# misleading "Step <last-step> failed (exit 0)" message that for hours
# masked real silent successes vs real failures across the engine.
# CURRENT_STEP is set by each step but never cleared between steps —
# kept that way intentionally, the exit-status guard now does the work.
CURRENT_STEP=""
DOCKER_IMAGE_CHANGED=""
trap '_exit_status=$?; if [ -n "$CURRENT_STEP" ] && [ "$_exit_status" -ne 0 ]; then log_error "Step '\''$CURRENT_STEP'\'' failed (exit $_exit_status)"; fi' EXIT

# ── Source all step files ─────────────────────────────────────────────
# Steps are in the same directory as this engine (1_workflows/src/scripts/)
STEPS_DIR="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")" && pwd)"
# Shared lib: stamps every dist/ artifact with the GENERATED-FILE banner.
# Template + prefix map live in 1_workflows/src/libs/generated-header.json.
INJECT_HEADER="$STEPS_DIR/../libs/inject-header.sh"
ENGINE_NAME="1_workflows/src/scripts/cloud-ship-container-engine.sh"
export INJECT_HEADER ENGINE_NAME
# Source step files — tolerate any missing step (graceful degradation).
# A step file may be absent inside cloud-builder when its /root/git/cloud
# clone is older than the engine's expected fileset (e.g. cloud-builder
# image baked before a new step script landed in the cloud repo, and the
# entrypoint's sync silently failed). Without `-f` guards, a missing file
# aborts the engine before it even prints the service name. Failure mode
# proven 2026-04-27 ship run 24994988037 — verify-secret-consumption.sh
# absent → 2 services failed before any step ran.
for _step in \
    cloud-ship-container-step-build-docker.sh \
    cloud-ship-container-step-build-configs.sh \
    cloud-ship-container-step-build-nix.sh \
    cloud-ship-container-step-docs.sh \
    cloud-ship-container-step-secrets-decrypt.sh \
    cloud-ship-container-step-verify-secret-consumption.sh \
    cloud-ship-container-step-deploy-rsync.sh \
    cloud-ship-container-step-deploy-compose.sh \
    cloud-ship-container-step-deploy-health.sh \
    cloud-ship-container-step-lifecycle.sh \
    cloud-ship-container-step-wrangler.sh \
    cloud-ship-container-step-wrangler-logs.sh \
    cloud-ship-container-step-terraform-apply.sh \
    cloud-ship-container-step-terraform-plan.sh \
    cloud-ship-container-step-terraform-import.sh \
    cloud-ship-container-step-clean.sh \
    cloud-ship-container-step-build-compose.sh; do
    if [ -f "$STEPS_DIR/$_step" ]; then
        # shellcheck disable=SC1090
        . "$STEPS_DIR/$_step"
    else
        log_warn "step file missing — skipping: $_step (engine drift; bump cloud-builder image)"
    fi
done
unset _step

# ── Main ─────────────────────────────────────────────────────────────
echo "========================================"
echo "  Build: $SERVICE_NAME"
echo "========================================"

case "${1:-all}" in
    docker)   step_docker ;;
    build)    step_build ;;
    docs)     step_docs ;;
    secrets)  step_secrets ;;
    verify)   step_verify_secrets ;;
    deploy)   step_deploy ;;
    compose)  step_compose ;;
    compose-build) step_compose_build ;;
    configs-push) step_configs_push ;;
    health)   step_health ;;
    all)      step_build; step_docs; step_secrets; step_verify_secrets ;;
    ship)
        # Runner: where to build Docker images (auto, local, oci-apps, gha)
        RUNNER="${2:-auto}"

        # Special cases: wrangler/terraform have their own flow.
        # NOTE: must `exit 0` (not `break`) — `break` is a no-op outside
        # a loop, so the case-arm continued into the standard pipeline,
        # double-running step_build + step_secrets.
        if [ "$WRANGLER_DEPLOY" = "true" ]; then
            step_build; step_secrets; step_wrangler; exit 0
        fi
        if [ "$TERRAFORM_DEPLOY" = "true" ]; then
            step_build; step_secrets; step_terraform; exit 0
        fi

        # ── Phase 1: BUILD (sequential — nix build produces dist/) ──
        rm -f "$SERVICE_DIR/.image-changed"
        step_build

        # ── Phase 2: 4 PARALLEL JOBS (docker + configs + compose-build + secrets) ──
        log "═══ Parallel: docker + configs-push + compose-build + secrets ═══"

        step_docker &
        PID_DOCKER=$!

        step_configs_push &
        PID_CONFIGS=$!

        step_compose_build &
        PID_IMAGE=$!

        step_secrets &
        PID_SECRETS=$!

        # Wait for all 4
        FAIL=0
        wait $PID_DOCKER   || { log_error "docker build failed"; exit 1; }
        wait $PID_CONFIGS  || { log_warn "configs-push failed"; FAIL=$((FAIL+1)); }
        wait $PID_IMAGE    || { log_warn "compose-build failed"; FAIL=$((FAIL+1)); }
        wait $PID_SECRETS  || { log_error "secrets failed"; FAIL=$((FAIL+1)); }
        [ $FAIL -gt 1 ] && { log_error "Too many parallel jobs failed ($FAIL/3)"; exit 1; }

        log "═══ Parallel jobs done ═══"

        # Read image-changed signal from background step_docker
        if [ -f "$SERVICE_DIR/.image-changed" ]; then
            DOCKER_IMAGE_CHANGED=true
            rm -f "$SERVICE_DIR/.image-changed"
        fi

        # ── Phase 2.5: VERIFY secret consumption (warn-mode in Phase 0) ──
        # Runs after both step_build (dist/configs/, dist/docker-compose.yml) AND
        # step_secrets (dist/.secrets*) have produced the artifacts the gate scans.
        # Mode is warn until repo-wide cleanup completes (Phase 8 flips to fail).
        step_verify_secrets || log_warn "verify-secrets reported offenders (warn mode)"

        # ── Phase 3: DEPLOY TO VM (skip if unchanged) ──
        NEW_HASH=$(find "$DIST_DIR" -type f -exec sha256sum {} \; 2>/dev/null | sort | sha256sum | cut -c1-16)
        if [ -n "$DEPLOY_HOST" ] && [ -n "$DEPLOY_PATH" ]; then
            OLD_HASH=$(ssh $SSH_OPTS "$DEPLOY_HOST" "cat '$DEPLOY_PATH/.dist-hash' 2>/dev/null" 2>/dev/null || true)
        else
            OLD_HASH=$(cat "$SERVICE_DIR/.dist-hash" 2>/dev/null || true)
        fi
        # Check secrets hash
        SECRETS_CHANGED=""
        if [ -f "$SERVICE_DIR/.secrets-hash-new" ]; then
            NEW_SECRETS_HASH=$(cat "$SERVICE_DIR/.secrets-hash-new")
            if [ -n "$DEPLOY_HOST" ] && [ -n "$DEPLOY_PATH" ]; then
                OLD_SECRETS_HASH=$(ssh $SSH_OPTS "$DEPLOY_HOST" "cat '$DEPLOY_PATH/.secrets-hash' 2>/dev/null" 2>/dev/null || true)
            else
                OLD_SECRETS_HASH=$(cat "$SERVICE_DIR/.secrets-hash" 2>/dev/null || true)
            fi
            [ "$NEW_SECRETS_HASH" != "$OLD_SECRETS_HASH" ] && SECRETS_CHANGED=true
        fi
        # Check container-presence on VM. Smart-skip is wrong if the desired
        # state (compose services running) doesn't match observed state — a
        # service whose source hash hasn't changed but whose container has
        # been stopped/removed otherwise silently stays down forever.
        CONTAINERS_MISSING=""
        if [ -n "$DEPLOY_HOST" ] && [ -n "$DEPLOY_PATH" ]; then
            EXPECTED=$(ssh $SSH_OPTS "$DEPLOY_HOST" \
                "docker compose -f '$DEPLOY_PATH/compose/docker-compose.yml' config --services 2>/dev/null | sort -u" 2>/dev/null)
            RUNNING=$(ssh $SSH_OPTS "$DEPLOY_HOST" \
                "docker compose -f '$DEPLOY_PATH/compose/docker-compose.yml' ps --services --status=running 2>/dev/null | sort -u" 2>/dev/null)
            if [ -n "$EXPECTED" ] && [ "$EXPECTED" != "$RUNNING" ]; then
                CONTAINERS_MISSING=true
                log_warn "Expected services not all running on $DEPLOY_HOST — forcing redeploy"
            fi
        fi
        if [ "$OLD_HASH" = "$NEW_HASH" ] && [ -n "$NEW_HASH" ] && [ -z "$DOCKER_IMAGE_CHANGED" ] && [ -z "$SECRETS_CHANGED" ] && [ -z "$CONTAINERS_MISSING" ] && [ -z "${FORCE_DEPLOY:-}" ]; then
            log "Config unchanged, no image rebuild, all containers running — skipping deploy+compose"
        else
            step_deploy
            step_compose
            # Bug #2 fix: hash written AFTER compose succeeds (not after deploy)
            echo "$NEW_HASH" > "$SERVICE_DIR/.dist-hash"
            if [ -n "$DEPLOY_HOST" ] && [ -n "$DEPLOY_PATH" ]; then
                ssh $SSH_OPTS "$DEPLOY_HOST" "echo '$NEW_HASH' > '$DEPLOY_PATH/.dist-hash'" 2>/dev/null || true
            fi
            if [ -f "$SERVICE_DIR/.secrets-hash-new" ]; then
                cp "$SERVICE_DIR/.secrets-hash-new" "$SERVICE_DIR/.secrets-hash"
                if [ -n "$DEPLOY_HOST" ] && [ -n "$DEPLOY_PATH" ]; then
                    ssh $SSH_OPTS "$DEPLOY_HOST" "echo '$NEW_SECRETS_HASH' > '$DEPLOY_PATH/.secrets-hash'" 2>/dev/null || true
                fi
                rm -f "$SERVICE_DIR/.secrets-hash-new"
            fi
        fi
        ;;
    wrangler) step_wrangler ;;
    logs)     shift; step_wrangler_logs "$@" ;;
    terraform) step_build; step_secrets; step_terraform ;;
    tf-plan) shift; step_build; step_secrets; step_terraform_plan "$@" ;;
    tf-import) step_build; step_secrets; step_terraform_import ;;
    redeploy) step_build; step_secrets; step_deploy; step_compose ;;
    clean)    rm -rf "$DIST_DIR" "$SERVICE_DIR/.result" "$SERVICE_DIR/.result-docs" "$SERVICE_DIR/.dist-hash"; log "Cleaned" ;;
    clean-remote) step_clean_remote "${2:-}" ;;
    *)
        # Try lifecycle command from build.json
        if [ -f "$CONFIG" ] && get_lifecycle "$1" | grep -q .; then
            run_lifecycle "$1"
        else
            echo "Usage: $0 [docker|build|docs|secrets|deploy|compose|health|wrangler|all|ship|redeploy|clean|clean-remote|<lifecycle>]"
            echo "  docker       Build + push Docker image"
            echo "  build        Build nix flake -> dist/"
            echo "  docs         Build documentation -> dist/docs/"
            echo "  secrets      Decrypt secrets -> dist/.secrets"
            echo "  deploy       Rsync dist/ -> VM (manifest-based, no --delete)"
            echo "  compose      Docker compose up on VM"
            echo "  health       Verify containers are healthy (post-deploy)"
            echo "  wrangler     Deploy Cloudflare Worker via wrangler"
            echo "  logs [since] [limit] [fmt]  Tail Cloudflare Worker observability logs (default: 15m, 100, pretty)"
            echo "  terraform    Terraform init + apply in dist/"
            echo "  tf-plan      build + secrets + terraform plan"
            echo "  tf-import    build + secrets + terraform import (from src/import.sh)"
            echo "  all          build + docs + secrets (default)"
            echo "  ship         docker + build + secrets + deploy + compose (skips if unchanged)"
            echo "  redeploy     build + secrets + deploy + compose (skip docker)"
            echo "  clean        Remove dist/ and build artifacts"
            echo "  clean-remote List non-manifest files on VM (--force to delete)"
            if [ -f "$CONFIG" ]; then
                LIFECYCLE_CMDS="$(node -e "const c=require('$CONFIG'); Object.keys(c.lifecycle||{}).forEach(k=>console.log('  '+k))" 2>/dev/null || python3 -c "import json; [print('  '+k) for k in json.load(open('$CONFIG')).get('lifecycle',{})]" 2>/dev/null)"
                if [ -n "$LIFECYCLE_CMDS" ]; then
                    echo ""
                    echo "Lifecycle commands:"
                    echo "$LIFECYCLE_CMDS"
                fi
            fi
        fi
        ;;
esac

CURRENT_STEP=""
log "Done."
