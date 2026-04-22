#!/bin/sh
set -e
echo "=== Ollama Startup ==="
echo "Waiting for Ollama API to be ready..."

# Wait for ollama to start (up to 60s)
for i in $(seq 1 60); do
  if docker exec @CONTAINER_NAME@ ollama list >/dev/null 2>&1; then
    echo "Ollama API ready."
    break
  fi
  sleep 1
done

echo "Pulling Q8 models..."
@PULL_MODELS@

echo ""
echo "=== Startup complete ==="
echo "API available at: http://@WG_IP@:@API_PORT@"
echo "Test: curl http://@WG_IP@:@API_PORT@/api/tags"
