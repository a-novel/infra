FROM docker.io/library/golang:1.27.3-alpine AS builder
ENV CGO_ENABLED=0
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY cmd/native-restore ./cmd/native-restore
COPY internal/recovery ./internal/recovery
RUN --mount=type=cache,target=/root/.cache/go-build \
    go build -ldflags="-s -w" -trimpath -o /native-restore ./cmd/native-restore

FROM ghcr.io/a-novel/service-json-keys/database:v2.13.4@sha256:8778711f5c9beb691b741b2edbbcccf4e5f857b0ff3380fbf2210dea194aab5a
COPY --from=builder /native-restore /native-restore
USER postgres
HEALTHCHECK NONE
ENTRYPOINT ["/native-restore"]
