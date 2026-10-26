# Runs tests/backup inside a service's database image with synthetic data only.
ARG DATABASE_SERVICE=json-keys
# A blank line separates each service's pin, so concurrent release pull requests merge cleanly. Git
# refuses to merge edits to adjacent lines.
FROM ghcr.io/a-novel/service-json-keys/database:v2.13.4@sha256:8778711f5c9beb691b741b2edbbcccf4e5f857b0ff3380fbf2210dea194aab5a AS json-keys

FROM ghcr.io/a-novel/service-authentication/database:v2.18.1@sha256:cce2b62f9486ddbf490e142525c444777782593845b1c2a6ab4ddab06eb94846 AS authentication

FROM ghcr.io/a-novel/service-genai/database:v0.7.1@sha256:b31cb76b7909f052e7bc2d417a32c9c1b15b54bb394059d07bc8709ad7dd48da AS genai

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
