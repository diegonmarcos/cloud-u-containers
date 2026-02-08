FROM python:3.11-alpine

WORKDIR /app

# Install dependencies
COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application
COPY app/main.py .

# Non-root user for security
RUN adduser -D -u 1000 appuser
USER appuser

# Expose port
EXPOSE 4182

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:4182/health || exit 1

# Run with gunicorn for production
CMD ["gunicorn", "--bind", "0.0.0.0:4182", "--workers", "2", "--threads", "2", "main:app"]
