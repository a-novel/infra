FROM docker.io/library/golang:1.27.1-alpine AS builder

ENV CGO_ENABLED=0
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY cmd/host-credentials ./cmd/host-credentials
COPY internal/hostcredentials ./internal/hostcredentials
RUN go build -ldflags="-s -w" -trimpath -o /host-credentials ./cmd/host-credentials

FROM docker.io/library/alpine:3.24.2
COPY --from=builder /host-credentials /host-credentials
USER 65532:65532
ENTRYPOINT ["/host-credentials"]
