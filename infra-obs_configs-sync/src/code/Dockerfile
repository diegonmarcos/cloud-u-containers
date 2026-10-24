FROM alpine:3.19

RUN apk add --no-cache bash git jq curl tzdata nodejs npm \
 && npm install -g tsx yaml ajv ajv-formats nunjucks

COPY entrypoint.sh containers-declared.mjs containers-guard.mjs /app/
RUN chmod +x /app/entrypoint.sh
WORKDIR /app
ENTRYPOINT ["/app/entrypoint.sh"]
