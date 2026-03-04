#!/bin/sh
set -e
echo "=== Ollama Startup ==="
echo "Waiting for Ollama API to be ready..."

# Wait for ollama to start (up to 60s)
for i in $(seq 1 60); do
  if docker exec ollama ollama list >/dev/null 2>&1; then
    echo "Ollama API ready."
    break
  fi
  sleep 1
done

echo "Pulling Q8 models..."
echo "  Pulling deepseek-r1:14b-qwen-distill-q8_0..."
docker exec ollama ollama pull deepseek-r1:14b-qwen-distill-q8_0
      echo "  Pulling qwen2.5:14b-instruct-q8_0..."
docker exec ollama ollama pull qwen2.5:14b-instruct-q8_0

echo ""
echo "=== Startup complete ==="
echo "API available at: http://10.0.0.8:11434"
echo "Test: curl http://10.0.0.8:11434/api/tags"
