# Runs tests/backup inside a service's database image with synthetic data only.
ARG DATABASE_SERVICE=json-keys
FROM ghcr.io/a-novel/service-json-keys/database:v2.12.3@sha256:8778711f5c9beb691b741b2edbbcccf4e5f857b0ff3380fbf2210dea194aab5a AS json-keys
FROM ghcr.io/a-novel/service-authentication/database:v2.15.2@sha256:a1a1536d9ac14aa037ee0df45f297ed5bcc86f6788badedef8d0434f13e28c2e AS authentication

FROM docker.io/library/golang:1.27.3-alpine AS builder
ENV CGO_ENABLED=0
WORKDIR /app
COPY go.mod go.sum ./
COPY internal/recovery ./internal/recovery
COPY tests/backup ./tests/backup
RUN go test -c -trimpath -o /backup.test ./tests/backup

FROM ${DATABASE_SERVICE}
COPY --from=builder /backup.test /backup.test
COPY internal/recovery/jsonKeysData.sql /jsonKeysData.sql
COPY internal/recovery/authenticationData.sql /authenticationData.sql
COPY modules/database-runtime/files/startup.sh /database-startup.sh
COPY modules/database-runtime/files/check-backup.sh /check-backup.sh
USER postgres
ENV BACKUP_TEST=1
ENTRYPOINT ["/backup.test", "-test.v", "-test.timeout=10m"]
