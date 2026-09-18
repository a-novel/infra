FROM docker.io/library/golang:1.27.1-alpine AS builder

ENV CGO_ENABLED=0
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY cmd/rollout-verifier ./cmd/rollout-verifier
COPY internal/rollout ./internal/rollout
RUN go build -ldflags="-s -w" -trimpath -o /rollout-verifier ./cmd/rollout-verifier

FROM docker.io/library/alpine:3.24.2
COPY --from=builder /rollout-verifier /rollout-verifier
USER 65532:65532
ENTRYPOINT ["/rollout-verifier"]
