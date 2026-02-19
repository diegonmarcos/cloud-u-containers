#!/bin/sh
# Cloudflare DNS - Terraform build/deploy script
# src/main.tf (native terraform) → dist/ (working dir) → terraform apply
# Sops uses ~/.config/sops/age/keys.txt automatically
set -e

SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SERVICE_DIR/src"
DIST_DIR="$SERVICE_DIR/dist"

log() { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$1"; }

# ── Step 1: Copy terraform source to dist/ ─────────────────────────────
step_build() {
    log "Copying src/main.tf → dist/"
    mkdir -p "$DIST_DIR"
    cp "$SRC_DIR/main.tf" "$DIST_DIR/main.tf"
    log "Build complete"
}

# ── Step 2: Decrypt secrets + generate terraform.tfvars ────────────────
step_secrets() {
    secrets_file="$SRC_DIR/secrets.yaml"
    template_file="$SRC_DIR/terraform.tfvars.template"

    if [ ! -f "$secrets_file" ]; then
        log "No secrets.yaml — skipping"
        return 0
    fi

    log "Decrypting secrets → dist/.secrets"
    mkdir -p "$DIST_DIR"

    if command -v yq >/dev/null 2>&1; then
        sops -d "$secrets_file" | yq -r 'to_entries | .[] | "\(.key)=\(.value)"' > "$DIST_DIR/.secrets"
    elif command -v python3 >/dev/null 2>&1; then
        sops -d "$secrets_file" | python3 -c "
import sys
for line in sys.stdin:
    line = line.strip()
    if line.startswith('sops:'):
        break
    if not line or line.startswith('#'):
        continue
    if ':' in line:
        k, v = line.split(':', 1)
        k, v = k.strip(), v.strip().strip('\"').strip(\"'\")
        if v:
            print(f'{k}={v}')
" > "$DIST_DIR/.secrets"
    else
        log "ERROR: No yq or python3 available"
        return 1
    fi

    log "Generating dist/terraform.tfvars from template + secrets"
    cp "$template_file" "$DIST_DIR/terraform.tfvars"

    # Inject secrets: replace INJECTED_FROM_SECRETS placeholders with real values
    while IFS='=' read -r key val; do
        case "$key" in "") continue ;; esac
        sed -i "s|^${key}.*= \"INJECTED_FROM_SECRETS\"|${key} = \"${val}\"|" "$DIST_DIR/terraform.tfvars"
    done < "$DIST_DIR/.secrets"

    log "terraform.tfvars ready ($(grep -c '=' "$DIST_DIR/terraform.tfvars") vars)"
}

# ── Step 3: Terraform init ─────────────────────────────────────────────
step_init() {
    log "Terraform init"
    terraform -chdir="$DIST_DIR" init -upgrade
}

# ── Step 4: Terraform plan ─────────────────────────────────────────────
step_plan() {
    log "Terraform plan"
    terraform -chdir="$DIST_DIR" plan
}

# ── Step 5: Terraform apply ────────────────────────────────────────────
step_apply() {
    log "Terraform apply"
    terraform -chdir="$DIST_DIR" apply -auto-approve
}

# ── Main ────────────────────────────────────────────────────────────────
echo "╔════════════════════════════════════════╗"
echo "║  Cloudflare DNS - Terraform            ║"
echo "╚════════════════════════════════════════╝"

case "${1:-all}" in
    build)   step_build ;;
    secrets) step_secrets ;;
    all)     step_build; step_secrets ;;
    init)    step_build; step_secrets; step_init ;;
    plan)    step_build; step_secrets; step_plan ;;
    ship)    step_build; step_secrets; step_init; step_apply ;;
    clean)   rm -rf "$DIST_DIR"; log "Cleaned" ;;
    *)
        echo "Usage: $0 [build|secrets|all|init|plan|ship|clean]"
        echo "  build    Copy src/main.tf → dist/"
        echo "  secrets  Decrypt secrets → dist/terraform.tfvars"
        echo "  all      build + secrets (default)"
        echo "  init     all + terraform init"
        echo "  plan     all + terraform plan"
        echo "  ship     all + terraform init + terraform apply  ← DEPLOY"
        echo "  clean    Remove dist/"
        ;;
esac

log "Done."
