FROM docker.io/library/golang:1.27.3-alpine AS builder
ENV CGO_ENABLED=0
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY cmd/native-restore ./cmd/native-restore
COPY internal/recovery ./internal/recovery
RUN --mount=type=cache,target=/root/.cache/go-build \
    go build -ldflags="-s -w" -trimpath -o /native-restore ./cmd/native-restore

FROM ghcr.io/a-novel/service-json-keys/database:v2.14.0@sha256:a7fd1aa7ba4476c6775e391fd632e0e292ca0667a25bec07a0cc3fab57afad3a
COPY --from=builder /native-restore /native-restore
USER postgres
HEALTHCHECK NONE
ENTRYPOINT ["/native-restore"]
