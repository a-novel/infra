#!/bin/sh
# The drill's check. The database must refuse a connection without TLS, naming the pg_hba.conf rule
# that refused it, before the check SQL in $1 runs over TLS. The attempt's answer goes to the log.
set -eu

if PGSSLMODE=disable psql --no-psqlrc --command 'SELECT 1' 2>&1 | tee /dev/stderr | grep -q 'pg_hba.conf rejects connection'; then
  exec psql --no-psqlrc --set=ON_ERROR_STOP=1 --command "$1"
fi

echo 'The database must refuse a connection without TLS.' >&2
exit 1
