# Evaluation only: no production image, credentials, or host data are consumed.
ARG DATABASE_SERVICE=json-keys
FROM ghcr.io/a-novel/service-json-keys/database:v2.8.0 AS json-keys
FROM ghcr.io/a-novel/service-authentication/database:v2.11.0 AS authentication

FROM docker.io/library/golang:1.27.1-alpine AS builder
ENV CGO_ENABLED=0
WORKDIR /app
COPY go.mod go.sum ./
COPY internal/recovery ./internal/recovery
COPY proofs/pgbackrest ./proofs/pgbackrest
RUN go test -c -trimpath -o /proof.test ./proofs/pgbackrest

FROM ${DATABASE_SERVICE}
COPY --from=builder /proof.test /proof.test
COPY internal/recovery/data.sql /data.sql
COPY assets/database-host/legacy-startup.sh /database-startup.sh
COPY assets/database-host/check-backup.sh /check-backup.sh
USER postgres
ENV INFRA_PGBACKREST_PROOF=1
ENTRYPOINT ["/proof.test", "-test.v", "-test.timeout=10m"]
