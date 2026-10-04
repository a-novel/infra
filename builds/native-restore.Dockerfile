FROM docker.io/library/golang:1.27.1-alpine AS builder
ENV CGO_ENABLED=0
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY cmd/native-restore ./cmd/native-restore
COPY internal/recovery ./internal/recovery
RUN go build -ldflags="-s -w" -trimpath -o /native-restore ./cmd/native-restore

FROM ghcr.io/a-novel/service-json-keys/database:v2.7.0
COPY --from=builder /native-restore /native-restore
USER postgres
HEALTHCHECK NONE
ENTRYPOINT ["/native-restore"]
