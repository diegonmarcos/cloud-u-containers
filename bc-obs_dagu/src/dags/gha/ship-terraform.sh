#!/usr/bin/env bash
# ── Run terraform plan+apply for cloud providers ──
# Usage: ship-terraform.sh [project]
#   project: cloudflare, gcloud, oci, aws, hetzner (omit for all)
set -euo pipefail

PROJECT="${1:-}"
REPO_ROOT="${GITHUB_WORKSPACE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$REPO_ROOT"

declare -A TF_DIRS=(
  [cloudflare]="c_vps/ba-clo_cloudflare/src"
  [gcloud]="c_vps/vps_gcloud/src"
  [oci]="c_vps/vps_oci/src"
  [aws]="c_vps/vps_aws/src"
  [hetzner]="c_vps/vps_hetzner/src"
)

OK=0; FAIL=0; SKIP=0

for name in cloudflare gcloud oci aws hetzner; do
  if [ -n "$PROJECT" ] && [ "$PROJECT" != "$name" ]; then
    continue
  fi

  dir="${TF_DIRS[$name]}"
  if [ ! -d "$dir" ]; then
    echo "SKIP $name (dir $dir not found)"
    SKIP=$((SKIP + 1))
    continue
  fi

  echo "── Terraform: $name ($dir) ──"
  cd "$REPO_ROOT/$dir"

  terraform init -input=false || { echo "FAIL $name (init)"; FAIL=$((FAIL + 1)); cd "$REPO_ROOT"; continue; }
  terraform plan -input=false -out=tfplan || { echo "FAIL $name (plan)"; FAIL=$((FAIL + 1)); cd "$REPO_ROOT"; continue; }
  terraform apply -input=false -auto-approve tfplan || { echo "FAIL $name (apply)"; FAIL=$((FAIL + 1)); cd "$REPO_ROOT"; continue; }

  echo "OK $name"
  OK=$((OK + 1))
  cd "$REPO_ROOT"
done

echo "Terraform: $OK ok, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
