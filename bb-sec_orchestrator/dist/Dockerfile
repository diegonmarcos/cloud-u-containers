FROM alpine:latest
RUN apk add --no-cache jq socat bc docker-cli
ENTRYPOINT ["/bin/sh", "/app/orchestrator.sh"]
