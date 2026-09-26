# Evaluation only: no production image, credentials, or host data are consumed.
FROM docker.io/library/golang:1.27.1-alpine AS builder
ENV CGO_ENABLED=0
WORKDIR /app
COPY go.mod go.sum ./
COPY proofs/pgbackrest ./proofs/pgbackrest
RUN go test -c -trimpath -o /proof.test ./proofs/pgbackrest

FROM ghcr.io/a-novel/service-json-keys/database:v2.6.1
# Installing the evaluation tools must preserve the service's server and extension binaries.
RUN sha256sum /usr/lib/postgresql/18/bin/postgres /usr/lib/postgresql/18/lib/uuid-ossp.so > /tmp/database.sha256 \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates pgbackrest=2.59.1-1.pgdg13+1 postgresql-17=17.11-1.pgdg13+2 \
    && sha256sum --check /tmp/database.sha256 \
    && rm -rf /var/lib/apt/lists/* /tmp/database.sha256
COPY --from=builder /proof.test /proof.test
USER postgres
ENV INFRA_PGBACKREST_PROOF=1
ENTRYPOINT ["/proof.test", "-test.v", "-test.timeout=10m"]
