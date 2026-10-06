# jev-sidecar (#881): the shared jev-gate directory (staged by the flake's extraFiles as jev-gate/)
# behind `jev-gate serve`. Stdlib Python only, no dependencies to install.
FROM python:3.13-slim

RUN useradd -r -m -u 10001 appuser && mkdir -p /home/appuser/.local/state /home/appuser/.cache \
    && chown -R appuser:appuser /home/appuser

COPY jev-gate/ /app/jev-gate/

ENV HOME=/home/appuser
USER appuser
EXPOSE 3110
CMD ["python3", "/app/jev-gate/jev_gate.py", "serve"]
