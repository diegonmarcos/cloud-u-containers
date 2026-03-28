#!/bin/sh
apt-get update && apt-get install -y --no-install-recommends netcat-openbsd && rm -rf /var/lib/apt/lists/*
echo "Forwarding alerts to $CENTRAL_HOST:$CENTRAL_PORT"
tail -F /var/log/sauron/alerts.jsonl 2>/dev/null | while read line; do
  echo "$line" | nc -w1 $CENTRAL_HOST $CENTRAL_PORT 2>/dev/null || true
done
