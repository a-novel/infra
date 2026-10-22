FROM docker.io/library/golang:1.27.3-alpine AS builder
ENV CGO_ENABLED=0
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY cmd/native-restore ./cmd/native-restore
COPY internal/recovery ./internal/recovery
RUN --mount=type=cache,target=/root/.cache/go-build \
    go build -ldflags="-s -w" -trimpath -o /native-restore ./cmd/native-restore

FROM ghcr.io/a-novel/service-json-keys/database:v2.12.1@sha256:f1072d3e67f7c333eb84c35b1be9bdad6bb3beae362a6d808b39f2f2ec073c11
COPY --from=builder /native-restore /native-restore
USER postgres
HEALTHCHECK NONE
ENTRYPOINT ["/native-restore"]
