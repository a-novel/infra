FROM docker.io/library/golang:1.27.3-alpine AS builder
ENV CGO_ENABLED=0
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY cmd/native-restore ./cmd/native-restore
COPY internal/recovery ./internal/recovery
RUN --mount=type=cache,target=/root/.cache/go-build \
    go build -ldflags="-s -w" -trimpath -o /native-restore ./cmd/native-restore

FROM ghcr.io/a-novel/service-json-keys/database:v2.10.4@sha256:392e831c21e44cca0a75ed0d10f241002ae56323e22f8569a086722f96434d0b
COPY --from=builder /native-restore /native-restore
USER postgres
HEALTHCHECK NONE
ENTRYPOINT ["/native-restore"]
