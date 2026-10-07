#!/bin/bash

# Restores one exact backup on the existing repository host, then checks SQL without networking.
set -euo pipefail
test "$#" = 7
service="$1"
instance="$2"
label="$3"
system_id="$4"
digest="$5"
size="$6"
schema_sql="$7"
case "$service" in json-keys|authentication) ;; *) exit 2 ;; esac
[[ "$instance" =~ ^[1-9][0-9]+$ && "$system_id" =~ ^[1-9][0-9]+$ ]]
[[ "$label" =~ ^[0-9]{8}-[0-9]{6}F$ && "$digest" =~ ^[a-f0-9]{64}$ ]]
[[ "$size" =~ ^[1-9][0-9]{0,9}$ && "$schema_sql" =~ ^[A-Za-z0-9+/=]+$ ]]
test "$(id -u)" = 0
test "$(curl -q --fail --silent --show-error --noproxy '*' --connect-timeout 5 --max-time 10 -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/id)" = "$instance"
systemctl is-active --quiet agora-backup-repository.service
image="$(docker inspect agora-backup-repository --format '{{.Config.Image}}')"
test "${image##*@sha256:}" = "$digest"
test "$size" -lt 2147483648
test "$(df --output=avail -B1 /mnt/stateful_partition | tail -n 1)" -gt "$((size * 3 + 1073741824))"
scratch="/mnt/stateful_partition/agora-maintenance-proof-$service-$label"
restore="agora-maintenance-restore-$service"
sql="agora-maintenance-sql-$service"
test ! -e "$scratch"
for container in "$restore" "$sql"; do
    if docker container inspect "$container" >/dev/null 2>&1; then exit 1; fi
done
umask 077
mkdir "$scratch"
install -d -o 999 -g 999 -m 0700 "$scratch/data" "$scratch/verification"
chown 999:999 "$scratch"

# Failures retain diagnostics and scratch data, but never leave a database running.
cleanup() {
    for container in "$restore" "$sql"; do
        if docker container inspect "$container" >/dev/null 2>&1; then
            docker stop --time=30 "$container" >/dev/null
        fi
    done
}
trap cleanup EXIT
trap 'exit 130' INT
printf '%s' "$schema_sql" | base64 -d > "$scratch/verification/verify.sql"
role="agora_${service//-/_}"
printf 'local all %s peer map=verification\n' "$role" > "$scratch/verification/pg_hba.conf"
printf 'verification postgres %s\n' "$role" > "$scratch/verification/pg_ident.conf"
printf '%s\n' "data_directory='/proof/data'" "hba_file='/proof/verification/pg_hba.conf'" "ident_file='/proof/verification/pg_ident.conf'" "listen_addresses=''" "unix_socket_directories='/proof/verification'" "unix_socket_permissions=0700" "shared_buffers='64MB'" "archive_mode=off" "restore_command='/usr/bin/false'" "recovery_target='immediate'" "recovery_target_action='pause'" "recovery_target_timeline='current'" "hot_standby=on" "default_transaction_read_only=on" "statement_timeout='30s'" > "$scratch/verification/postgresql.conf"
cat > "$scratch/verification/verify.sh" <<'VERIFY'
#!/bin/bash
set -euo pipefail
test "$#" = 2
role="$1"
system_id="$2"
test "$(id -u)" = 999
test "$(</proof/data/PG_VERSION)" = 18
mv /proof/data/postgresql.auto.conf /proof/verification/restored.auto.conf
touch /proof/data/postgresql.auto.conf
cleanup() {
    if test -f /proof/data/postmaster.pid; then pg_ctl -D /proof/data -m fast -w -t 30 stop; fi
}
trap cleanup EXIT
trap 'exit 130' INT
pg_ctl -D /proof/data -l /proof/verification/postgres.log -o '-c config_file=/proof/verification/postgresql.conf' -w -t 60 start
for ((attempt=0; attempt<30; attempt++)); do
    observed="$(psql -XqAt -h /proof/verification -U "$role" -d "$role" -v ON_ERROR_STOP=1 -c 'SELECT system_identifier, pg_is_in_recovery(), pg_get_wal_replay_pause_state() FROM pg_control_system()')"
    case "$observed" in
        "$system_id|t|paused") break ;;
        "$system_id|t|"*) sleep 1 ;;
        *) exit 1 ;;
    esac
done
test "$observed" = "$system_id|t|paused"
test "$(psql -XqAt -h /proof/verification -U "$role" -d "$role" -v ON_ERROR_STOP=1 -f /proof/verification/verify.sql)" = t
pg_ctl -D /proof/data -m fast -w -t 30 stop
test ! -e /proof/data/postmaster.pid
VERIFY
chown 999:999 "$scratch/verification/"*
common=(--pull=never --user=999:999 --read-only --cap-drop=ALL --security-opt=no-new-privileges --cpus=0.5 --memory=256m --memory-swap=256m --pids-limit=64 --no-healthcheck --ulimit=core=0 --log-driver=json-file --log-opt=max-size=2m --log-opt=max-file=2 '--tmpfs=/tmp:rw,noexec,nosuid,nodev,size=16m,mode=1777')
# Only the file-restoration container gets the repository's cloud identity. Its native
# configuration fixes the bucket/prefix; the SQL container has neither network nor credentials.
docker run --name="$restore" "${common[@]}" --network=host --mount="type=bind,source=$scratch/data,target=/proof/data" --mount=type=bind,source=/etc/agora-backup/pgbackrest.conf,target=/etc/pgbackrest/pgbackrest.conf,readonly --entrypoint=pgbackrest "$image" --stanza="$service" --set="$label" --archive-mode=off --type=immediate --target-action=pause --process-max=1 --io-timeout=10 --log-level-file=off --log-level-console=info --pg1-path=/proof/data restore
test "$(docker inspect "$restore" --format '{{.State.ExitCode}}')" = 0
docker run --name="$sql" "${common[@]}" --network=none --mount="type=bind,source=$scratch,target=/proof" --entrypoint=/bin/bash "$image" /proof/verification/verify.sh "$role" "$system_id"
test "$(docker inspect "$sql" --format '{{.State.ExitCode}}')" = 0
test "$(docker inspect "$sql" --format '{{.HostConfig.NetworkMode}}')" = none
systemctl is-active --quiet agora-backup-repository.service
for container in "$restore" "$sql"; do test "$(docker inspect "$container" --format '{{.State.Running}}')" = false; done
docker rm "$restore" "$sql" >/dev/null
test ! -e "$scratch/data/postmaster.pid"
test "$(realpath "$scratch")" = "$scratch"
rm -rf -- "$scratch"
test ! -e "$scratch"
printf 'sql-verified:%s:%s\n' "$system_id" "$label"
