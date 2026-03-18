FROM python:3.11-slim

WORKDIR /app

RUN apt-get update && apt-get install -y \
    curl git \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir uv

# Clone the repo (pinned to main — update hash to pin a release)
RUN git clone --depth 1 https://github.com/taylorwilsdon/google_workspace_mcp.git .

# Install dependencies
RUN uv sync --frozen --no-dev --extra disk

# Non-root user
RUN useradd --create-home --shell /bin/bash app \
    && chown -R app:app /app

RUN mkdir -p /app/store_creds \
    && chown -R app:app /app/store_creds \
    && chmod 755 /app/store_creds

USER app

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD sh -c 'curl -f http://localhost:${PORT:-8000}/health || exit 1'

ENV TOOL_TIER=""
ENV TOOLS=""

ENTRYPOINT ["/bin/sh", "-c"]
CMD ["uv run main.py --transport streamable-http ${TOOL_TIER:+--tool-tier \"$TOOL_TIER\"} ${TOOLS:+--tools $TOOLS}"]
