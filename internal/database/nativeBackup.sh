#!/bin/bash

# Runs the existing native workers once; stdout contains only source identity and catalog.
set -euo pipefail
test "$#" = 3
service="$1"
instance="$2"
digest="$3"
case "$service" in json-keys|authentication) ;; *) exit 2 ;; esac
[[ "$instance" =~ ^[1-9][0-9]+$ && "$digest" =~ ^[a-f0-9]{64}$ ]]
test "$(id -u)" = 0
test "$(curl -q --fail --silent --show-error --noproxy '*' --connect-timeout 5 --max-time 10 -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/id)" = "$instance"
systemctl is-active --quiet agora-database.service
image="$(docker inspect "agora-postgres-$service" --format '{{.Config.Image}}')"
test "${image##*@sha256:}" = "$digest"
role="agora_${service//-/_}"
identity="$(docker exec --user=999:999 "agora-postgres-$service" psql -XqAt -h /var/run/postgresql -U "$role" -d "$role" -v ON_ERROR_STOP=1 -c 'SELECT system_identifier FROM pg_control_system() WHERE NOT pg_is_in_recovery()')"
[[ "$identity" =~ ^[1-9][0-9]+$ ]]
for kind in check full; do
    test "$(systemctl show "agora-backup-$kind.service" --property=ActiveState --value)" = inactive
    systemctl start --wait "agora-backup-$kind.service"
    test "$(systemctl show "agora-backup-$kind.service" --property=Result --value)" = success
    test "$(systemctl show "agora-backup-$kind.service" --property=ExecMainStatus --value)" = 0
    test "$(docker inspect "agora-backup-$kind" --format '{{.State.ExitCode}}')" = 0
done
systemctl is-active --quiet agora-database.service
printf '%s\n' "$identity"
docker exec --user=999:999 "agora-postgres-$service" pgbackrest --stanza="$service" --output=json info
