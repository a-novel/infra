#!/usr/bin/env bash
# Warn through the existing backup-check unit before either TLS chain expires.
# Only the hourly check uses this preflight; backup and archive workers remain native.
set -euo pipefail

if (( $# < 4 )); then
  printf 'Usage: check-backup.sh SERVER CA IDENTITY PGBACKREST_ARGUMENTS...\n' >&2
  exit 1
fi
server="$1"
ca="$2"
identity="$3"
shift 3

valid_until=$(( $(date +%s) + 30 * 24 * 60 * 60 ))
printf 'Checking backup TLS chains remain valid for at least 30 days.\n'
openssl verify -attime "$valid_until" -purpose sslclient \
  -CAfile "$ca" -untrusted "$identity" "$identity"
timeout -k 5 20 openssl s_client \
  -connect "$server:8432" -servername "$server" -verify_hostname "$server" \
  -verify_return_error -attime "$valid_until" -CAfile "$ca" \
  -cert "$identity" -key "$identity" -brief -no_ign_eof </dev/null

exec pgbackrest "$@"
