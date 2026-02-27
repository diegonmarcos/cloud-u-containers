#!/bin/sh
# Cloudflare DNS: src/*.tf → dist/ (terraform runs in dist/)
# Secrets: sops decrypt → dist/terraform.tfvars (injected from template)
set -e

SERVICE_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SERVICE_DIR/src"
DIST_DIR="$SERVICE_DIR/dist"

log() { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$1"; }

# Run terraform in dist/ (state + providers live there)
tf() { (cd "$DIST_DIR" && terraform "$@"); }

# ── Build — copy src/*.tf → dist/ ──────────────────────────────────────
step_build() {
    log "Copying src/*.tf → dist/"
    mkdir -p "$DIST_DIR"
    cp "$SRC_DIR"/*.tf "$DIST_DIR/"
    log "Built → dist/"
}

# ── Docs — build documentation from nix flake ─────────────────────────
step_docs() {
    log "Building documentation..."
    cd "$SRC_DIR"

    nix build .#docs --out-link "$SERVICE_DIR/.result-docs"

    mkdir -p "$DIST_DIR/docs"
    cp -rL "$SERVICE_DIR/.result-docs/"* "$DIST_DIR/docs/"
    chmod -R u+w "$DIST_DIR/docs"
    rm -f "$SERVICE_DIR/.result-docs"

    log "Documentation built → dist/docs/"
}

# ── Secrets — decrypt + generate terraform.tfvars ──────────────────────
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

# ── Init ────────────────────────────────────────────────────────────────
step_init() {
    step_build
    step_secrets
    log "terraform init"
    tf init -upgrade
}

# ── Plan ────────────────────────────────────────────────────────────────
step_plan() {
    step_build
    step_secrets
    log "terraform plan"
    tf plan
}

# ── Apply (interactive) ────────────────────────────────────────────────
step_apply() {
    step_build
    step_secrets
    log "terraform apply"
    tf apply
}

# ── Ship (build + secrets + init + apply -auto-approve) ────────────────
step_ship() {
    step_build
    step_secrets
    log "terraform init"
    tf init -upgrade
    log "terraform apply -auto-approve"
    tf apply -auto-approve
}

# ── Destroy ─────────────────────────────────────────────────────────────
step_destroy() {
    step_build
    step_secrets
    log "terraform destroy"
    tf destroy
}

# ── Fmt ─────────────────────────────────────────────────────────────────
step_fmt() {
    log "terraform fmt"
    terraform fmt "$SRC_DIR"
}

# ── Clean — remove generated files only (keeps state + .terraform/) ────
step_clean() {
    log "Removing generated files from dist/"
    rm -f "$DIST_DIR"/*.tf "$DIST_DIR/.secrets" "$DIST_DIR/terraform.tfvars"
    rm -rf "$DIST_DIR/docs"
    rm -f "$SERVICE_DIR/.result-docs"
}

# ── Main ────────────────────────────────────────────────────────────────
echo "╔════════════════════════════════════════╗"
echo "║  Cloudflare DNS - Terraform            ║"
echo "╚════════════════════════════════════════╝"

case "${1:-plan}" in
    build)    step_build ;;
    docs)     step_docs ;;
    secrets)  step_secrets ;;
    all)      step_build; step_docs; step_secrets ;;
    init)     step_init ;;
    plan)     step_plan ;;
    apply)    step_apply ;;
    ship)     step_ship ;;
    destroy)  step_destroy ;;
    fmt)      step_fmt ;;
    clean)    step_clean ;;
    *)
        echo "Usage: $0 [build|docs|secrets|all|init|plan|apply|ship|destroy|fmt|clean]"
        echo "  build    Copy src/*.tf → dist/"
        echo "  docs     Build documentation → dist/docs/"
        echo "  secrets  Decrypt secrets → dist/terraform.tfvars"
        echo "  all      build + docs + secrets (default)"
        echo "  init     build + secrets + terraform init"
        echo "  plan     build + secrets + terraform plan (default)"
        echo "  apply    build + secrets + terraform apply (interactive)"
        echo "  ship     build + secrets + init + apply -auto-approve"
        echo "  destroy  build + secrets + terraform destroy"
        echo "  fmt      terraform fmt src/"
        echo "  clean    Remove generated files (keeps state)"
        ;;
esac

log "Done."
