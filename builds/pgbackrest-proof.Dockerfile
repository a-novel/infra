# Evaluation only: no production image, credentials, or host data are consumed.
FROM docker.io/library/golang:1.27.1-alpine AS builder
ENV CGO_ENABLED=0
WORKDIR /app
COPY go.mod go.sum ./
COPY proofs/pgbackrest ./proofs/pgbackrest
RUN go test -c -trimpath -o /proof.test ./proofs/pgbackrest

FROM docker.io/library/postgres:18.6-trixie
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates pgbackrest=2.59.1-1.pgdg13+1 postgresql-17=17.11-1.pgdg13+2 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /proof.test /proof.test
USER postgres
ENV INFRA_PGBACKREST_PROOF=1
ENTRYPOINT ["/proof.test", "-test.v", "-test.timeout=10m"]
