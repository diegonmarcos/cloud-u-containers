for C in my-ai-api my-ai_claude-api hermes-agent; do
  echo "$C:"
  docker inspect "$C" --format '{{range .Mounts}}  {{.Name}} -> {{.Destination}}
{{end}}' 2>/dev/null | grep -v '^\s*$' | head -5
done
