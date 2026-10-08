# Runs tests/backup inside a service's database image with synthetic data only.
ARG DATABASE_SERVICE=json-keys
FROM ghcr.io/a-novel/service-json-keys/database:v2.8.0 AS json-keys
FROM ghcr.io/a-novel/service-authentication/database:v2.11.1 AS authentication

FROM docker.io/library/golang:1.27.2-alpine AS builder
ENV CGO_ENABLED=0
WORKDIR /app
COPY go.mod go.sum ./
COPY internal/recovery ./internal/recovery
COPY tests/backup ./tests/backup
RUN go test -c -trimpath -o /backup.test ./tests/backup

FROM ${DATABASE_SERVICE}
COPY --from=builder /backup.test /backup.test
COPY internal/recovery/data.sql /data.sql
COPY internal/recovery/authenticationData.sql /authenticationData.sql
COPY modules/database-runtime/files/startup.sh /database-startup.sh
COPY modules/database-runtime/files/check-backup.sh /check-backup.sh
USER postgres
ENV BACKUP_TEST=1
ENTRYPOINT ["/backup.test", "-test.v", "-test.timeout=10m"]
