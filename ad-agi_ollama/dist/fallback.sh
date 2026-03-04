#!/bin/sh
set -e
echo "=== Ollama Fallback Check ==="

GCP_WG_IP="10.0.0.8"
API_PORT="11434"
VASTAI_API_KEY="${VASTAI_API_KEY:-}"

# Check if GCP spot VM is alive via WireGuard
echo "Checking GCP spot VM at $GCP_WG_IP..."
if curl -sf --connect-timeout 5 "http://$GCP_WG_IP:$API_PORT/api/tags" >/dev/null 2>&1; then
  echo "GCP spot VM is alive and Ollama is responding."
  echo "No fallback needed."
  exit 0
fi

echo "GCP spot VM is DOWN or unreachable."
echo ""

if [ -z "$VASTAI_API_KEY" ]; then
  echo "ERROR: VASTAI_API_KEY not set. Cannot provision fallback."
  echo "Set it via: export VASTAI_API_KEY=<key>"
  echo "Or add to secrets.yaml and run: source <(sops -d secrets.yaml)"
  exit 1
fi

echo "Searching Vast.ai for available GPU instances..."
echo ""
echo "To provision manually:"
echo "  1. Visit https://cloud.vast.ai/search"
echo "  2. Search for RTX A4000 or T4 (16GB VRAM)"
echo "  3. Select cheapest spot/on-demand instance"
echo "  4. Deploy with: vastai create instance <id> --image ollama/ollama --disk 50"
echo "  5. SSH in and run startup.sh to pull models"
echo ""
echo "To provision via CLI (requires vastai pip package):"
echo "  vastai search offers 'gpu_ram>=16 num_gpus=1 dph<0.30 inet_down>200' -o dph"
echo "  vastai create instance <OFFER_ID> --image ollama/ollama:latest --disk 50"
