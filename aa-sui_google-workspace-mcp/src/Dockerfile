FROM python:3.11-slim

WORKDIR /app

RUN apt-get update && apt-get install -y \
    curl \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir uv

# Vendored source (no git clone at build time)
COPY app/ .

# Install dependencies
RUN uv sync --frozen --no-dev --extra disk

# Non-root user
RUN useradd --create-home --shell /bin/bash app \
    && chown -R app:app /app

RUN mkdir -p /app/store_creds \
    && chown -R app:app /app/store_creds \
    && chmod 755 /app/store_creds

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD sh -c 'curl -f http://localhost:${PORT:-8000}/health || exit 1'

CMD ["uv", "run", "main.py", "--transport", "streamable-http", "--tool-tier", "complete"]
