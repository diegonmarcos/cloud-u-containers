FROM python:3.11-slim
WORKDIR /app
COPY smtp_proxy.py .
LABEL org.opencontainers.image.source="https://github.com/diegonmarcos/cloud"

EXPOSE 8080
CMD ["python3", "smtp_proxy.py"]
