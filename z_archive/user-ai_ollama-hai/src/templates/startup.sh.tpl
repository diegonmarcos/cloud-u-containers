#!/bin/sh
set -e
echo "=== Ollama HAI Startup ==="
echo "Waiting for Ollama API to be ready..."

for i in $(seq 1 60); do
  if curl -sf http://localhost:@API_PORT@/api/tags >/dev/null 2>&1; then
    echo "Ollama API ready."
    break
  fi
  sleep 1
done

echo "Pulling models (Q4, CPU-optimized)..."
@PULL_COMMANDS@

echo ""
echo "=== Startup complete ==="
echo "API available at: http://@WG_IP@:@API_PORT@"
echo "Test: curl http://@WG_IP@:@API_PORT@/api/tags"
echo "Embeddings: curl http://@WG_IP@:@API_PORT@/v1/embeddings -d '{\"model\":\"nomic-embed-text\",\"input\":\"test\"}'"
