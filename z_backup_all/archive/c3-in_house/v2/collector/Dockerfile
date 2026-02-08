FROM python:3.11-slim

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-client \
    curl \
    cron \
    && rm -rf /var/lib/apt/lists/*

# Create app directory
WORKDIR /app

# Copy collectors and converters
COPY 1.collectors/ /app/collectors/
COPY 3.converters/ /app/converters/
COPY main.py /app/

# Create output directories
RUN mkdir -p /app/2.raw /app/4.jsons

# Create cron schedule
RUN echo "# C3 Collector Cron Schedule" > /etc/cron.d/c3-collectors && \
    echo "*/5 * * * * root cd /app && python3 collectors/1.availability.py >> /var/log/c3.log 2>&1" >> /etc/cron.d/c3-collectors && \
    echo "*/15 * * * * root cd /app && python3 collectors/1.performance.py >> /var/log/c3.log 2>&1" >> /etc/cron.d/c3-collectors && \
    echo "*/15 * * * * root cd /app && python3 collectors/0.docker.py >> /var/log/c3.log 2>&1" >> /etc/cron.d/c3-collectors && \
    echo "0 * * * * root cd /app && python3 collectors/2.security.py >> /var/log/c3.log 2>&1" >> /etc/cron.d/c3-collectors && \
    echo "0 * * * * root cd /app && python3 collectors/2.web.py >> /var/log/c3.log 2>&1" >> /etc/cron.d/c3-collectors && \
    echo "0 */6 * * * root cd /app && python3 collectors/2.backups.py >> /var/log/c3.log 2>&1" >> /etc/cron.d/c3-collectors && \
    echo "0 0 * * * root cd /app && python3 collectors/3.cost_infra.py >> /var/log/c3.log 2>&1" >> /etc/cron.d/c3-collectors && \
    echo "0 0 * * * root cd /app && python3 collectors/3.cost_ai.py >> /var/log/c3.log 2>&1" >> /etc/cron.d/c3-collectors && \
    echo "0 * * * * root cd /app && python3 collectors/0.architecture.py >> /var/log/c3.log 2>&1" >> /etc/cron.d/c3-collectors && \
    echo "*/15 * * * * root cd /app && python3 converters/to_json.py >> /var/log/c3.log 2>&1" >> /etc/cron.d/c3-collectors && \
    echo "" >> /etc/cron.d/c3-collectors && \
    chmod 0644 /etc/cron.d/c3-collectors

# Create log file
RUN touch /var/log/c3.log

# Start script
COPY <<EOF /app/start.sh
#!/bin/bash
echo "Starting C3 Cloud Control Center..."
echo "Running initial collection..."
cd /app
python3 main.py collect 2>&1 | head -50
python3 converters/to_json.py 2>&1
echo "Starting cron daemon..."
cron
echo "C3 running. Tailing logs..."
tail -f /var/log/c3.log
EOF

RUN chmod +x /app/start.sh

CMD ["/app/start.sh"]
