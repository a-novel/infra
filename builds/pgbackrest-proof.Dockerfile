# Evaluation only: no production image, credentials, or host data are consumed.
ARG DATABASE_SERVICE=json-keys
FROM ghcr.io/a-novel/service-json-keys/database:v2.6.5 AS json-keys
FROM ghcr.io/a-novel/service-authentication/database:v2.10.0 AS authentication

FROM docker.io/library/golang:1.27.1-alpine AS builder
ENV CGO_ENABLED=0
WORKDIR /app
COPY go.mod go.sum ./
COPY internal/recovery ./internal/recovery
COPY proofs/pgbackrest ./proofs/pgbackrest
RUN go test -c -trimpath -o /proof.test ./proofs/pgbackrest

FROM ${DATABASE_SERVICE}
COPY --from=builder /proof.test /proof.test
USER postgres
ENV INFRA_PGBACKREST_PROOF=1
ENTRYPOINT ["/proof.test", "-test.v", "-test.timeout=10m"]
