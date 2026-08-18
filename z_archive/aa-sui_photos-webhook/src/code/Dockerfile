FROM python:3.12-slim

WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -y \
    postgresql-client \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Copy requirements
COPY requirements.txt .

# Install Python dependencies
RUN pip install --no-cache-dir -r requirements.txt

# Copy application
COPY webhook.py .

HEALTHCHECK --interval=10s --timeout=5s --retries=5 \
    CMD curl -f http://localhost:${WEBHOOK_PORT:-5002}/health || exit 1

LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud-infra"

# Run webhook processor
CMD ["python", "webhook.py", "flask"]
