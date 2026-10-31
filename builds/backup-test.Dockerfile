# Runs tests/backup inside a service's database image with synthetic data only.
ARG DATABASE_SERVICE=json-keys
# A blank line separates each service's pin, so concurrent release pull requests merge cleanly. Git
# refuses to merge edits to adjacent lines.
FROM ghcr.io/a-novel/service-json-keys/database:v2.14.1@sha256:a7fd1aa7ba4476c6775e391fd632e0e292ca0667a25bec07a0cc3fab57afad3a AS json-keys

FROM ghcr.io/a-novel/service-authentication/database:v2.20.1@sha256:cce2b62f9486ddbf490e142525c444777782593845b1c2a6ab4ddab06eb94846 AS authentication

FROM ghcr.io/a-novel/service-genai/database:v0.8.2@sha256:369e9a0be29523f014eae389a2a638454af6f24b0844286795bac3969c1667e3 AS genai

FROM docker.io/library/golang:1.27.3-alpine AS builder
ENV CGO_ENABLED=0
WORKDIR /app
COPY go.mod go.sum ./
COPY internal/recovery ./internal/recovery
COPY tests/backup ./tests/backup
RUN go test -c -trimpath -o /backup.test ./tests/backup

FROM ${DATABASE_SERVICE}
ARG DATABASE_SERVICE
COPY --from=builder /backup.test /backup.test
COPY internal/recovery/*Data.sql /
COPY modules/database-runtime/files/startup.sh /database-startup.sh
COPY modules/database-runtime/files/check-backup.sh /check-backup.sh
USER postgres
ENV BACKUP_TEST=1 DATABASE_SERVICE=${DATABASE_SERVICE}
ENTRYPOINT ["/backup.test", "-test.v", "-test.timeout=10m"]
