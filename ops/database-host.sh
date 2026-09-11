#!/bin/bash

# Inspects and opens the private database host without persisting host coordinates.

set -euo pipefail

usage() {
    cat >&2 <<EOF
Usage:
  $0 coordinates
  $0 inspect <authentication|json-keys>
  $0 key [--key-file <path>]
  $0 ssh <authentication|json-keys> [--key-file <path>] [--ttl <duration>]
  $0 troubleshoot <authentication|json-keys> [--key-file <path>] [--ttl <duration>]
EOF
    exit 64
}

fail() {
    printf 'FAIL %s\n' "$1" >&2
    exit "${2:-70}"
}

pass() {
    printf 'PASS %s\n' "$1"
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        fail "$1 is required" 69
    fi
}

COMMAND="${1:-}"
if [ -z "$COMMAND" ]; then
    usage
fi
shift

case "$COMMAND" in
    inspect | ssh | troubleshoot)
        DATABASE_SERVICE="${1:-}"
        case "$DATABASE_SERVICE" in authentication | json-keys) ;; *) usage ;; esac
        shift
        if [ "$COMMAND" = inspect ]; then [ "$#" -eq 0 ] || usage; fi
        ;;
    coordinates) [ "$#" -eq 0 ] || usage ;;
    key) ;;
    *) usage ;;
esac

KEY_FILE="${HOME}/.ssh/a-novel-gcp-ed25519"
KEY_TTL='1h'

while [ "$#" -gt 0 ]; do
    case "$1" in
        --key-file)
            [ "$#" -ge 2 ] || usage
            KEY_FILE="$2"
            shift 2
            ;;
        --ttl)
            [ "$COMMAND" != key ] || usage
            [ "$#" -ge 2 ] || usage
            KEY_TTL="$2"
            shift 2
            ;;
        *)
            usage
            ;;
    esac
done

if [ "$COMMAND" = ssh ] || [ "$COMMAND" = troubleshoot ]; then
    if ! [[ "$KEY_TTL" =~ ^[1-9][0-9]*(s|m|h|d)$ ]]; then
        fail 'SSH key TTL is invalid' 64
    fi
fi
if [ "$COMMAND" != inspect ]; then
    if [ -z "$KEY_FILE" ] || [[ "$KEY_FILE" == *$'\n'* ]]; then
        fail 'SSH key path is invalid' 64
    fi
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORKLOAD_PROJECT_ID=''
DATABASE_GROUP="agora-database-${DATABASE_SERVICE:-}"
DATABASE_DISK="agora-data-${DATABASE_SERVICE:-}"
DATABASE_SNAPSHOT_POLICY="agora-${DATABASE_SERVICE:-}-daily-snapshots"
DATABASE_ZONE=''
DATABASE_REGION=''
DATABASE_INSTANCE=''
DATABASE_PRIVATE_IP=''

load_cloud_context() {
    "${SCRIPT_DIR}/verify-operator-env.sh" >/dev/null
    WORKLOAD_PROJECT_ID="$INFRA_WORKLOAD_PROJECT_ID"
    require_command gcloud
    export CLOUDSDK_CORE_DISABLE_PROMPTS=1
}

load_host() {
    DATABASE_ZONE="$(gcloud compute instance-groups managed list \
        --project="$WORKLOAD_PROJECT_ID" \
        --filter="name=${DATABASE_GROUP}" \
        --format='value(zone.basename())')"
    if ! [[ "$DATABASE_ZONE" =~ ^[a-z]+-[a-z]+[0-9]+-[a-z]$ ]]; then
        fail 'expected exactly one database group zone'
    fi
    DATABASE_REGION="${DATABASE_ZONE%-*}"

    DATABASE_INSTANCE="$(gcloud compute instance-groups managed list-instances \
        "$DATABASE_GROUP" \
        --project="$WORKLOAD_PROJECT_ID" \
        --zone="$DATABASE_ZONE" \
        --format='value(instance.basename())')"
    if ! [[ "$DATABASE_INSTANCE" =~ ^${DATABASE_GROUP}-[a-z0-9]+$ ]]; then
        fail 'expected exactly one generated database instance'
    fi

    DATABASE_PRIVATE_IP="$(gcloud compute instances describe "$DATABASE_INSTANCE" \
        --project="$WORKLOAD_PROJECT_ID" \
        --zone="$DATABASE_ZONE" \
        --format='value(networkInterfaces[0].networkIP)')"
    if ! [[ "$DATABASE_PRIVATE_IP" =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)[0-9.]+$ ]]; then
        fail 'database instance does not have one private address'
    fi
}

ensure_key() {
    local public_key_file="${KEY_FILE}.pub"
    local key_type

    require_command ssh-keygen
    umask 077

    if [ ! -e "$KEY_FILE" ] && [ ! -e "$public_key_file" ]; then
        mkdir -p -- "$(dirname -- "$KEY_FILE")"
        ssh-keygen -t ed25519 -a 64 -C 'a-novel-database-operator' -f "$KEY_FILE"
    elif [ ! -f "$KEY_FILE" ] || [ ! -f "$public_key_file" ]; then
        fail 'SSH private and public key files must both exist' 64
    fi

    if [ ! -s "$KEY_FILE" ] || [ ! -s "$public_key_file" ]; then
        fail 'SSH key pair is empty' 64
    fi
    read -r key_type _ <"$public_key_file"
    case "$key_type" in
        ssh-ed25519 | ecdsa-sha2-*) ;;
        *) fail 'use an Ed25519 or ECDSA SSH key' 64 ;;
    esac

    pass 'local SSH key pair'
}

inspect_host() {
    load_cloud_context
    load_host

    printf 'Database group: %s\nDatabase instance: %s\nZone: %s\nPrivate IP: %s\n' \
        "$DATABASE_GROUP" "$DATABASE_INSTANCE" "$DATABASE_ZONE" "$DATABASE_PRIVATE_IP"

    gcloud compute instance-groups managed describe "$DATABASE_GROUP" \
        --project="$WORKLOAD_PROJECT_ID" --zone="$DATABASE_ZONE" \
        --format='yaml(name,targetSize,instanceGroup,updatePolicy,statefulPolicy,status)'
    gcloud compute instances describe "$DATABASE_INSTANCE" \
        --project="$WORKLOAD_PROJECT_ID" --zone="$DATABASE_ZONE" \
        --format='yaml(name,status,machineType,networkInterfaces,serviceAccounts,tags.items,shieldedInstanceConfig,disks.deviceName,disks.boot,disks.autoDelete,disks.mode,disks.source)'
    gcloud compute disks describe "$DATABASE_DISK" \
        --project="$WORKLOAD_PROJECT_ID" --zone="$DATABASE_ZONE" \
        --format='yaml(name,status,sizeGb,type,physicalBlockSizeBytes,users,labels)'
    gcloud compute resource-policies describe "$DATABASE_SNAPSHOT_POLICY" \
        --project="$WORKLOAD_PROJECT_ID" --region="$DATABASE_REGION" \
        --format='yaml(name,region,snapshotSchedulePolicy)'
    gcloud compute snapshots list --project="$WORKLOAD_PROJECT_ID" \
        --filter="labels.application=agora AND labels.environment=production AND labels.role=database-snapshot AND labels.component=${DATABASE_SERVICE}" \
        --sort-by='~creationTimestamp' --limit=1 \
        --format='table(name,autoCreated,status,creationTimestamp,sourceDisk.basename(),storageLocations,labels.role)'

    for rule in \
        agora-allow-${DATABASE_SERVICE}-postgres-ingress \
        agora-allow-json-keys-postgres-egress \
        agora-allow-authentication-postgres-egress \
        agora-allow-iap-ssh \
        agora-deny-other-vpc-egress; do
        gcloud compute firewall-rules describe "$rule" \
            --project="$WORKLOAD_PROJECT_ID" \
            --format='yaml(name,direction,priority,sourceRanges,destinationRanges,allowed,denied,targetTags)'
    done

    gcloud monitoring policies list --project="$WORKLOAD_PROJECT_ID" \
        --filter='display_name:("Agora database")' \
        --format='table(display_name,enabled,severity,conditions[0].display_name)'
    gcloud monitoring policies list --project="$WORKLOAD_PROJECT_ID" \
        --filter='display_name="Agora PostgreSQL recovery jobs unhealthy"' \
        --format='table(display_name,enabled,severity,conditions[0].display_name)'
    pass 'database host inspection'
}

open_ssh() {
    local -a extra_arguments=()

    load_cloud_context
    ensure_key
    load_host
    if [ "$COMMAND" = troubleshoot ]; then
        extra_arguments+=(--troubleshoot)
    fi
    gcloud compute ssh "$DATABASE_INSTANCE" \
        --project="$WORKLOAD_PROJECT_ID" \
        --zone="$DATABASE_ZONE" \
        --ssh-key-file="$KEY_FILE" \
        --ssh-key-expire-after="$KEY_TTL" \
        --tunnel-through-iap \
        "${extra_arguments[@]}"
}

coordinates() {
    local hosts='{}' zone='' disk_id=''
    load_cloud_context
    require_command jq
    for DATABASE_SERVICE in authentication json-keys; do
        DATABASE_GROUP="agora-database-${DATABASE_SERVICE}"
        load_host
        if [ -n "$zone" ] && [ "$zone" != "$DATABASE_ZONE" ]; then
            fail 'database hosts must use the same configured zone'
        fi
        zone="$DATABASE_ZONE"
        disk_id="$(gcloud compute disks describe "agora-data-${DATABASE_SERVICE}" --project="$WORKLOAD_PROJECT_ID" --zone="$DATABASE_ZONE" --format='value(id)')"
        [[ "$disk_id" =~ ^[1-9][0-9]*$ ]] || fail 'invalid database disk ID'
        hosts="$(jq -c --arg service "${DATABASE_SERVICE//-/_}" --arg ip "$DATABASE_PRIVATE_IP" --arg disk "$disk_id" '. + {($service): {private_ip: $ip, data_disk_id: $disk}}' <<<"$hosts")"
    done
    jq -cn --arg zone "$zone" --argjson hosts "$hosts" '{zone: $zone, hosts: $hosts}'
}

case "$COMMAND" in
    coordinates) coordinates ;;
    inspect) inspect_host ;;
    key) ensure_key ;;
    ssh | troubleshoot) open_ssh ;;
esac
