# Evaluation only: no production image, credentials, or host data are consumed.
ARG DATABASE_SERVICE=json-keys
FROM ghcr.io/a-novel/service-json-keys/database:v2.6.2 AS json-keys
FROM ghcr.io/a-novel/service-authentication/database:v2.9.2 AS authentication

FROM docker.io/library/golang:1.27.1-alpine AS builder
ENV CGO_ENABLED=0
WORKDIR /app
COPY go.mod go.sum ./
COPY proofs/pgbackrest ./proofs/pgbackrest
RUN go test -c -trimpath -o /proof.test ./proofs/pgbackrest

FROM ${DATABASE_SERVICE}
# The negative-test server must not replace the service's database or backup tool.
RUN sha256sum /usr/lib/postgresql/18/bin/postgres /usr/lib/postgresql/18/lib/uuid-ossp.so /usr/bin/pgbackrest > /tmp/database.sha256 \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        postgresql-17=17.11-1.pgdg13+2 \
    && sha256sum --check /tmp/database.sha256 \
    && rm -rf /var/lib/apt/lists/* /tmp/database.sha256
COPY --from=builder /proof.test /proof.test
USER postgres
ENV INFRA_PGBACKREST_PROOF=1
ENTRYPOINT ["/proof.test", "-test.v", "-test.timeout=10m"]
