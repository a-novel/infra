#!/bin/bash

# Exercises Authentication's bounded restart and metadata rollback under the
# release workflow lock. SQL connection continuity remains human-held evidence.
# Usage: drill-database-isolation.sh <drill|restore> <receipt-id> <confirmation> <config-file>

set -euo pipefail
umask 077

fail() { printf 'STOP: %s\n' "$1" >&2; exit 70; }

if [ "$#" -ne 4 ]; then
    printf 'Usage: %s <drill|restore> <receipt-id> <confirmation> <config-file>\n' "$0" >&2
    exit 64
fi
OPERATION="$1"
TARGET_RECEIPT="$2"
CONFIRMATION="$3"
CONFIG_FILE="$4"
case "$OPERATION" in
    drill) [ "$CONFIRMATION" = 'DRILL authentication' ] || exit 64 ;;
    restore) [ "$CONFIRMATION" = 'RESTORE authentication' ] || exit 64 ;;
    *) exit 64 ;;
esac
[[ "$TARGET_RECEIPT" =~ ^[1-9][0-9]*-[1-9][0-9]*$ ]] && [ -f "$CONFIG_FILE" ] || exit 64
[[ "${GITHUB_SHA:-}" =~ ^[a-f0-9]{40}$ ]] &&
    [[ "${GITHUB_RUN_ID:-}" =~ ^[1-9][0-9]*$ ]] &&
    [[ "${GITHUB_RUN_ATTEMPT:-}" =~ ^[1-9][0-9]*$ ]] &&
    [ "${GITHUB_REPOSITORY:-}" = a-novel/infra ] &&
    [ "${GITHUB_EVENT_NAME:-}" = workflow_dispatch ] &&
    [ "${GITHUB_WORKFLOW_REF:-}" = 'a-novel/infra/.github/workflows/release.yaml@refs/heads/master' ] ||
    fail 'Use the protected master release workflow.'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RECEIPT_BUCKET="${RECEIPT_BUCKET:?RECEIPT_BUCKET is required}"
SCRATCH="$(mktemp -d)"
MUTATED=false
RESTORE_ATTEMPTED=false
RESTORED=false
PEER_UNCHANGED=false
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

restore_authentication() {
    RESTORE_ATTEMPTED=true
    "${SCRIPT_DIR}/restore-database-release.sh" "$PROJECT" "$ZONE" authentication "$AUTH_DISK" "$SCRATCH/database.json" || return
    RESTORED=true
    MUTATED=false
}

cleanup() {
    local code=$?
    trap - EXIT INT TERM
    if [ "$MUTATED" = true ] && [ "$RESTORE_ATTEMPTED" = false ]; then
        printf 'Restoring Authentication after the interrupted drill.\n' >&2
        if ! restore_authentication; then
            printf 'STOP: automatic restoration failed; use the protected restore-database-isolation action.\n' >&2
            code=70
        fi
    fi
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        {
            printf '## Database isolation %s\n\n' "$OPERATION"
            printf 'Source receipt: %s\n\n' "$TARGET_RECEIPT"
            printf 'Started: %s; finished: %s\n\n' "$STARTED_AT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            printf 'Exit status: %s; Authentication restored: %s; JSON Keys host unchanged: %s.\n\n' "$code" "$RESTORED" "$PEER_UNCHANGED"
            printf 'Connection continuity requires the human psql probe covering this entire interval. This workflow does not attest SQL continuity.\n'
        } >>"$GITHUB_STEP_SUMMARY"
    fi
    rm -rf -- "$SCRATCH"
    exit "$code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

check_latest_receipt() {
    "${SCRIPT_DIR}/receipt-custody.sh" latest "$RECEIPT_BUCKET" "$SCRATCH/latest.json" || return
    jq -e --arg target "$TARGET_RECEIPT" '
      ([.sequence.runId, (.sequence.runAttempt | tostring)] | join("-")) == $target and
      .activeTfvars.application_release != null and .database.hosts != null
    ' "$SCRATCH/latest.json" >/dev/null || return
    if [ -f "$SCRATCH/receipt.json" ]; then
        [ "$(sha256sum <"$SCRATCH/receipt.json")" = "$(sha256sum <"$SCRATCH/latest.json")" ] || return
    fi
}
check_latest_receipt || fail 'Select the latest successful two-host receipt; a newer release requires a new baseline.'
cp "$SCRATCH/latest.json" "$SCRATCH/receipt.json"

# The existing compiler validates the image families, protected coordinates and
# pinned versions. Restore uses the receipt manifest even if Renovate moved master.
MANIFEST="${SCRIPT_DIR}/../deploy/production/images.yaml"
if [ "$OPERATION" = restore ]; then
    jq '.imageManifest' "$SCRATCH/receipt.json" >"$SCRATCH/images.json"
    MANIFEST="$SCRATCH/images.json"
fi
RELEASE_ACTION=deploy CURRENT_RECEIPT="$SCRATCH/receipt.json" \
    "${SCRIPT_DIR}/compile-release.mjs" "$MANIFEST" "$CONFIG_FILE" "$SCRATCH/receipt.json" "$SCRATCH/compiled"
RELEASE_FILE="$SCRATCH/compiled/release.json"
jq -e '
  .action == "deploy" and .mode == "maintenance" and
  .database == .previousDatabase and .database == .currentDatabase and
  .imageManifest == .previousManifest
' "$RELEASE_FILE" >/dev/null || fail 'Deploy pending image or database configuration changes separately from this drill.'
PROJECT="$(jq -r '.cloud.workloadProjectId' "$RELEASE_FILE")"
ZONE="$(jq -r '.cloud.databaseZone' "$RELEASE_FILE")"
AUTH_DISK="$(jq -r '.cloud.databaseHosts.authentication.data_disk_id' "$RELEASE_FILE")"
jq '.previousDatabase' "$RELEASE_FILE" >"$SCRATCH/database.json"
ORIGINAL_REVISION="$(jq -r '.hosts.authentication.releaseRevision' "$SCRATCH/database.json")"

expected_metadata() {
    local service="$1"
    jq -cS --arg service "$service" '
      (if $service == "json-keys" then "json_keys" else $service end) as $key |
      (if $service == "json-keys" then "jsonKeys" else $service end) as $prefix |
      {
        "agora-database-release-revision": .hosts[$key].releaseRevision,
        ("agora-\($service)-database-image"): .[$prefix + "Image"],
        ("agora-\($service)-postgres-password-version"): (.[$prefix + "PasswordVersion"] | tostring),
        ("agora-\($service)-postgres-backup-password-version"): (.[$prefix + "BackupPasswordVersion"] | tostring)
      }
    ' "$SCRATCH/database.json"
}

# Normalize stable identity fields only. The peer's start time and guest boot
# status remain part of the comparison, so a restart cannot disappear in noise.
inspect_host() {
    local service="$1" output="$2" instance key disk_id expected_ip guest
    key="${service//-/_}"
    gcloud compute instance-groups managed describe "agora-database-${service}" --project="$PROJECT" --zone="$ZONE" --format=json >"$SCRATCH/group.json" || return
    jq -e '
      .targetSize == 1 and .status.isStable == true and
      .status.versionTarget.isReached == true and .status.allInstancesConfig.effective == true and
      .updatePolicy.type == "OPPORTUNISTIC" and
      .statefulPolicy.preservedState.disks["agora-data"].autoDelete == "NEVER" and
      .statefulPolicy.preservedState.internalIPs.nic0.autoDelete == "NEVER"
    ' "$SCRATCH/group.json" >/dev/null || return
    instance="$(gcloud compute instance-groups managed list-instances "agora-database-${service}" --project="$PROJECT" --zone="$ZONE" --format='value(instance.basename())')" || return
    [[ "$instance" =~ ^agora-database-${service}-[a-z0-9]+$ ]] || return 70
    gcloud compute instances describe "$instance" --project="$PROJECT" --zone="$ZONE" --format=json >"$SCRATCH/vm.json" || return
    disk_id="$(gcloud compute disks describe "agora-data-${service}" --project="$PROJECT" --zone="$ZONE" --format='value(id)')" || return
    [ "$disk_id" = "$(jq -r --arg key "$key" '.hosts[$key].dataDiskId' "$SCRATCH/database.json")" ] || return 70
    expected_ip="$(jq -r --arg key "$key" '.hosts[$key].privateIp' "$SCRATCH/database.json")"
    jq -e --arg ip "$expected_ip" --arg disk "/projects/$PROJECT/zones/$ZONE/disks/agora-data-$service" '
      .status == "RUNNING" and (.id | tostring | test("^[1-9][0-9]*$")) and
      (.lastStartTimestamp | type == "string" and length > 0) and
      (.networkInterfaces | length == 1) and .networkInterfaces[0].networkIP == $ip and
      ((.networkInterfaces[0].accessConfigs // []) | length == 0) and
      ([.disks[] | select(.deviceName == "agora-data" and .boot == false and .autoDelete == false and (.source | endswith($disk)))] | length == 1)
    ' "$SCRATCH/vm.json" >/dev/null || return
    guest="$("${SCRIPT_DIR}/database-host-readiness.sh" current "$PROJECT" "$ZONE" "$service")" || return
    jq -nSc --slurpfile group "$SCRATCH/group.json" --slurpfile vm "$SCRATCH/vm.json" --arg disk "$disk_id" --arg guest "$guest" '{
      metadata: $group[0].allInstancesConfig.properties.metadata,
      template: $group[0].instanceTemplate, versions: $group[0].versions,
      instance: $vm[0].name, id: $vm[0].id, started: $vm[0].lastStartTimestamp,
      interfaces: [$vm[0].networkInterfaces[] | {network, subnetwork, networkIP}],
      disks: [$vm[0].disks[] | {source, deviceName, boot, autoDelete}],
      dataDiskId: $disk, guest: $guest
    }' >"$output"
}

check_peer() {
    inspect_host json-keys "$SCRATCH/peer-after.json" || return
    [ "$(sha256sum <"$SCRATCH/peer-before.json")" = "$(sha256sum <"$SCRATCH/peer-after.json")" ] || return
}

inspect_host authentication "$SCRATCH/auth-before.json" || fail 'Authentication host is not stable on the receipt-owned disk and address.'
inspect_host json-keys "$SCRATCH/peer-before.json" || fail 'JSON Keys host is not stable on the receipt-owned disk and address.'
PEER_METADATA="$(expected_metadata json-keys)"
jq -e --argjson expected "$PEER_METADATA" '
  .metadata == $expected and (.guest | startswith("healthy:" + $expected["agora-database-release-revision"] + ":"))
' "$SCRATCH/peer-before.json" >/dev/null || fail 'JSON Keys differs from the selected healthy receipt.'
AUTH_METADATA="$(expected_metadata authentication)"
if [ "$OPERATION" = drill ]; then
    [ "$GITHUB_SHA" != "$ORIGINAL_REVISION" ] || fail 'The drill commit must differ from the recorded Authentication release revision.'
    jq -e --argjson expected "$AUTH_METADATA" '
      .metadata == $expected and (.guest | startswith("healthy:" + $expected["agora-database-release-revision"] + ":"))
    ' "$SCRATCH/auth-before.json" >/dev/null || fail 'Authentication differs from the healthy receipt; use restore-database-isolation after an interrupted drill.'
    "${SCRIPT_DIR}/preflight-release.sh" "$RELEASE_FILE"
    expected_hash="$(printf '%s' "$AUTH_METADATA" | sha256sum | cut -d ' ' -f 1)"
    "${SCRIPT_DIR}/prepare-database-change.sh" "$PROJECT" "$ZONE" authentication "$AUTH_DISK" "$GITHUB_SHA" "$SCRATCH/proof.json" "$expected_hash"
else
    # Recovery can repair only revision drift, never changed images or passwords.
    jq -e --argjson expected "$AUTH_METADATA" '
      (.metadata["agora-database-release-revision"] | test("^[a-f0-9]{40}$")) and
      (.metadata | del(.["agora-database-release-revision"])) == ($expected | del(.["agora-database-release-revision"]))
    ' "$SCRATCH/auth-before.json" >/dev/null || fail 'Restore refuses image, credential, or metadata-shape drift.'
fi
check_latest_receipt || fail 'The selected receipt changed during preflight.'
check_peer || fail 'JSON Keys changed during preflight.'

if [ "$OPERATION" = drill ]; then
    mapfile -t database < <(jq -r '[.authenticationImage, (.authenticationPasswordVersion | tostring), (.authenticationBackupPasswordVersion | tostring)][]' "$SCRATCH/database.json")
    MUTATED=true
    DATABASE_CHANGE_PROOF="$SCRATCH/proof.json" "${SCRIPT_DIR}/deploy-database-release.sh" "$PROJECT" "$ZONE" authentication "$AUTH_DISK" "$GITHUB_SHA" "${database[@]}"
    check_peer || fail 'JSON Keys changed during the Authentication restart.'
fi
MUTATED=true
restore_authentication || fail 'Restoration failed; do not retry the drill. Use the protected restore-database-isolation action.'
inspect_host authentication "$SCRATCH/auth-after.json" || fail 'Authentication inspection failed after restoration.'
jq -e --argjson expected "$AUTH_METADATA" --slurpfile before "$SCRATCH/auth-before.json" '
  .metadata == $expected and (.guest | startswith("healthy:" + $expected["agora-database-release-revision"] + ":")) and
  (del(.metadata, .started, .guest) == ($before[0] | del(.metadata, .started, .guest)))
' "$SCRATCH/auth-after.json" >/dev/null || fail 'Authentication did not restore the original metadata on the same host and disks.'
check_peer || fail 'JSON Keys changed during the Authentication rollback.'
PEER_UNCHANGED=true
printf 'PASS Authentication metadata restored; JSON Keys host unchanged. Verify the human connection probe before accepting isolation.\n'
