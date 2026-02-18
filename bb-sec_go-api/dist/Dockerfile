FROM golang:1.23-alpine AS builder
WORKDIR /build
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o /go-api .

FROM alpine:3.20
RUN apk add --no-cache ca-certificates curl openssh-client iputils
RUN adduser -D -u 1000 appuser
WORKDIR /app
COPY --from=builder /go-api /app/go-api
USER appuser
EXPOSE 8090
HEALTHCHECK --interval=30s --timeout=10s --retries=3 --start-period=10s \
    CMD curl -f http://localhost:8090/go/health || exit 1
CMD ["/app/go-api"]
