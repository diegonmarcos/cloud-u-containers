FROM python:3.11-slim

WORKDIR /app

# Install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application
COPY main.py .

# Non-root user for security
RUN useradd -r -u 1000 appuser
USER appuser

# ── Bind address (data-driven from build.json via Docker --build-arg) ──
# Defaults mirror build.json (bind_host=10.0.0.1, ports.app=4182). The engine
# (cloud-ship-container-step-build-docker.sh) MUST pass these as --build-arg
# so HEALTHCHECK + CMD probe the same wg0-only address gunicorn binds to.
# 0.0.0.0 is forbidden by wg0-only policy; localhost is unreachable from the
# host network namespace where Caddy lives.
ARG BIND_HOST=10.0.0.1
ARG BIND_PORT=4182
ENV BIND_HOST=${BIND_HOST}
ENV BIND_PORT=${BIND_PORT}

# Expose port (informational; host-network bypasses publish)
EXPOSE ${BIND_PORT}

# Health check — probes the actual bind address (host network + wg0-only =
# no localhost listener). BIND_HOST/BIND_PORT come from build.json via build-args.
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD python3 -c "import os,urllib.request; urllib.request.urlopen(f\"http://{os.environ['BIND_HOST']}:{os.environ['BIND_PORT']}/health\")" || exit 1

LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud"
LABEL org.opencontainers.image.dockerfile-path="a_solutions/bb-sec_introspect-proxy/src/code/Dockerfile"

# Run with gunicorn for production — bind matches HEALTHCHECK (data-driven).
CMD ["sh", "-c", "exec gunicorn --bind ${BIND_HOST}:${BIND_PORT} --workers 1 --threads 1 --timeout 120 main:app"]
