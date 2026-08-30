#!/bin/bash

# Audits unmanaged and additive workload-foundation security boundaries. It
# stays separate from foundation.sh so review-only access cannot reach a
# mutation branch by selecting the wrong subcommand.

set -euo pipefail

usage() {
    printf 'Usage: %s [--final]\n' "$0" >&2
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

is_private_24_cidr() {
    local first
    local second
    local third
    local fourth

    if ! [[ "$1" =~ ^10\.[0-9]{1,3}\.[0-9]{1,3}\.0/24$ ]]; then
        return 1
    fi
    IFS=. read -r first second third fourth <<<"${1%/24}"
    [ "$first" -eq 10 ] && [ "$second" -le 255 ] &&
        [ "$third" -le 255 ] && [ "$fourth" -eq 0 ]
}

FINAL_AUDIT=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --final)
            FINAL_AUDIT=true
            shift
            ;;
        *)
            usage
            ;;
    esac
done

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
"${SCRIPT_DIR}/verify-operator-env.sh" >/dev/null
WORKLOAD_PROJECT_ID="$INFRA_WORKLOAD_PROJECT_ID"
MANAGEMENT_PROJECT_ID="$INFRA_MANAGEMENT_PROJECT_ID"

for command_name in gh gcloud grep jq; do
    require_command "$command_name"
done

export CLOUDSDK_CORE_DISABLE_PROMPTS=1
umask 077

REPOSITORY='a-novel/infra'
BACKUP_BUCKET_NAME="$(gh variable get GCP_BACKUP_BUCKET --repo "$REPOSITORY")"
PUBLISHED_MANAGEMENT_PROJECT_ID="$(gh variable get GCP_MANAGEMENT_PROJECT_ID \
    --repo "$REPOSITORY")"
if [ "$PUBLISHED_MANAGEMENT_PROJECT_ID" != "$MANAGEMENT_PROJECT_ID" ]; then
    fail 'INFRA_MANAGEMENT_PROJECT_ID does not match GCP_MANAGEMENT_PROJECT_ID'
fi
if ! [[ "$BACKUP_BUCKET_NAME" =~ ^[a-z0-9][a-z0-9._-]{1,221}[a-z0-9]$ ]]; then
    fail 'backup bucket coordinate is invalid'
fi
FOUNDATION_MEMBER="serviceAccount:infra-foundation@${MANAGEMENT_PROJECT_ID}.iam.gserviceaccount.com"

audit_foundation() {
    local project_json
    local billing_json
    local services_json
    local policy_json
    local cloud_run_service_agent
    local service_accounts
    local key_names
    local networks_json
    local network_url
    local subnetworks_json
    local production_subnet_cidr
    local routes_json
    local firewalls_json
    local products_json
    local repositories_json
    local repository_json
    local repository_location
    local repository_policy
    local project_number
    local tag_keys_json
    local invocation_key
    local tag_values_json
    local initializer_tag_value
    local initializer_tag_policy
    local initializer_service_account_policy
    local secret_inventory
    local secret_policy
    local expected_secret_services
    local initializer_members
    local backup_policy_json
    local required_services_json
    local allowed_auxiliary_services_json
    local missing_services
    local unexpected_services
    local service_name
    local -a expected_secrets

    project_json="$(gcloud projects describe "$WORKLOAD_PROJECT_ID" --format=json)"
    if ! jq --exit-status '
      .projectId != null and
      .lifecycleState == "ACTIVE" and
      .labels.application == "agora" and
      .labels.environment == "production" and
      .labels["managed-by"] == "opentofu" and
      .labels.plane == "workload" and
      .labels.recovery == "false"
    ' <<<"$project_json" >/dev/null; then
        fail 'workload project identity'
    fi
    pass 'workload project identity'

    project_number="$(jq --raw-output '.projectNumber' <<<"$project_json")"
    if ! [[ "$project_number" =~ ^[0-9]+$ ]]; then
        fail 'workload project number'
    fi
    cloud_run_service_agent="serviceAccount:service-${project_number}@serverless-robot-prod.iam.gserviceaccount.com"

    billing_json="$(gcloud billing projects describe "$WORKLOAD_PROJECT_ID" --format=json)"
    if ! jq --exit-status '.billingEnabled == true' <<<"$billing_json" >/dev/null; then
        fail 'workload billing link'
    fi
    pass 'workload billing link'

    services_json="$(gcloud services list --enabled --project="$WORKLOAD_PROJECT_ID" --format=json)"
    required_services_json='[
        "artifactregistry.googleapis.com",
        "cloudquotas.googleapis.com",
        "cloudresourcemanager.googleapis.com",
        "cloudscheduler.googleapis.com",
        "compute.googleapis.com",
        "dns.googleapis.com",
        "iam.googleapis.com",
        "iap.googleapis.com",
        "logging.googleapis.com",
        "monitoring.googleapis.com",
        "oslogin.googleapis.com",
        "run.googleapis.com",
        "serviceusage.googleapis.com"
      ]'
    # Google can enable defaults and service dependencies beside the APIs
    # OpenTofu owns. The explicit auxiliary set keeps new products reviewable.
    allowed_auxiliary_services_json='[
        "cloudtrace.googleapis.com",
        "containerregistry.googleapis.com",
        "iamcredentials.googleapis.com",
        "pubsub.googleapis.com",
        "storage-api.googleapis.com",
        "storage-component.googleapis.com",
        "telemetry.googleapis.com"
      ]'
    missing_services="$(jq --raw-output \
        --argjson required "$required_services_json" '
          ([.[].config.name] | unique) as $actual
          | ($required - $actual)[]?
        ' <<<"$services_json")"
    unexpected_services="$(jq --raw-output \
        --argjson required "$required_services_json" \
        --argjson auxiliary "$allowed_auxiliary_services_json" '
          ([.[].config.name] | unique) as $actual
          | ($actual - ($required + $auxiliary))[]?
        ' <<<"$services_json")"
    if [ -n "$missing_services" ] || [ -n "$unexpected_services" ]; then
        while IFS= read -r service_name; do
            [ -n "$service_name" ] && printf 'MISSING_API=%s\n' "$service_name" >&2
        done <<<"$missing_services"
        while IFS= read -r service_name; do
            [ -n "$service_name" ] && printf 'UNEXPECTED_API=%s\n' "$service_name" >&2
        done <<<"$unexpected_services"
        fail 'enabled service boundary'
    fi
    pass 'enabled service boundary'

    policy_json="$(gcloud projects get-iam-policy "$WORKLOAD_PROJECT_ID" --format=json)"
    if ! jq --exit-status '
      all(.bindings[]?.members[]?;
        . != "allUsers" and . != "allAuthenticatedUsers"
      )
    ' <<<"$policy_json" >/dev/null; then
        fail 'no public project IAM principals'
    fi
    pass 'no public project IAM principals'

    if [ "$FINAL_AUDIT" = true ]; then
        if ! jq --exit-status '
          [
            .bindings[]?
            | select(.role == "roles/owner" or .role == "roles/editor")
            | .members[]?
            | select(startswith("serviceAccount:"))
          ] | length == 0
        ' <<<"$policy_json" >/dev/null; then
            fail 'primitive service-account roles'
        fi
    else
        if ! jq --exit-status --arg foundation "$FOUNDATION_MEMBER" '
          [
            .bindings[]?
            | select(.role == "roles/owner" or .role == "roles/editor")
            | {role, members: [.members[]? | select(startswith("serviceAccount:"))]}
            | select(.members | length > 0)
          ] as $primitive
          | ($primitive | length <= 1) and
            all($primitive[];
              .role == "roles/owner" and .members == [$foundation]
            )
        ' <<<"$policy_json" >/dev/null; then
            fail 'primitive service-account roles'
        fi
    fi
    pass 'primitive service-account roles'

    initializer_members="$(jq --compact-output --arg role \
        "projects/${WORKLOAD_PROJECT_ID}/roles/authenticationInitializerDeployer" '
      [
        .bindings[]?
        | select(.role == $role)
        | .members[]?
      ] | sort | unique
    ' <<<"$policy_json")"
    if ! jq --exit-status '
      (length >= 1) and
      all(.[]; startswith("user:") or startswith("group:"))
    ' <<<"$initializer_members" >/dev/null; then
        fail 'human-only Authentication initializer deployment'
    fi

    # Google creates an unconditional service-agent grant when Cloud Run is enabled.
    if ! jq --exit-status --arg service_agent "$cloud_run_service_agent" '
      [
        .bindings[]?
        | select(.role == "roles/run.serviceAgent")
        | {
            role,
            title: .condition.title,
            expression: .condition.expression,
            members: (.members | sort)
          }
      ] == [{
        role: "roles/run.serviceAgent",
        title: null,
        expression: null,
        members: [$service_agent]
      }]
    ' <<<"$policy_json" >/dev/null; then
        fail 'Cloud Run service agent IAM'
    fi
    pass 'Cloud Run service agent IAM'

    if ! jq --exit-status \
        --arg release "serviceAccount:infra-release@${MANAGEMENT_PROJECT_ID}.iam.gserviceaccount.com" \
        --arg scheduler "serviceAccount:agora-scheduler-invoker@${WORKLOAD_PROJECT_ID}.iam.gserviceaccount.com" \
        --arg authentication "serviceAccount:agora-authentication@${WORKLOAD_PROJECT_ID}.iam.gserviceaccount.com" \
        --argjson initializers "$initializer_members" '
      [
        .bindings[]?
        | select(
            (.role | startswith("roles/run.")) and
            .role != "roles/run.serviceAgent"
          )
        | {
            role,
            title: .condition.title,
            expression: .condition.expression,
            members: (.members | sort)
          }
      ] as $bindings
      | ($bindings | length == 4) and
        all($bindings[]; .expression | contains("resource.matchTagId(")) and
        any($bindings[];
          .role == "roles/run.jobsExecutor" and
          .title == "AuthenticationInitializerOnly" and
          .members == $initializers
        ) and
        any($bindings[];
          .role == "roles/run.jobsExecutor" and
          .title == "ReleaseTaggedCloudRunOnly" and
          .members == [$release]
        ) and
        any($bindings[];
          .role == "roles/run.jobsExecutor" and
          .title == "ScheduledCloudRunOnly" and
          .members == [$scheduler]
        ) and
        any($bindings[];
          .role == "roles/run.servicesInvoker" and
          .title == "InternalCloudRunOnly" and
          .members == [$authentication]
        )
    ' <<<"$policy_json" >/dev/null; then
        fail 'conditional Cloud Run invocation IAM'
    fi
    pass 'conditional Cloud Run invocation IAM'

    service_accounts="$(gcloud iam service-accounts list \
        --project="$WORKLOAD_PROJECT_ID" --format='value(email)')"
    if [ -z "$service_accounts" ]; then
        fail 'service-account inventory'
    fi
    while IFS= read -r account_email; do
        [ -n "$account_email" ] || continue
        key_names="$(gcloud iam service-accounts keys list \
            --project="$WORKLOAD_PROJECT_ID" \
            --iam-account="$account_email" \
            --managed-by=user --format='value(name)')"
        if [ -n "$key_names" ]; then
            fail 'zero user-managed service-account keys'
        fi
    done <<<"$service_accounts"
    pass 'zero user-managed service-account keys'

    expected_secrets=(
        production-authentication-postgres-dsn
        production-authentication-postgres-password
        production-authentication-postgres-backup-password
        production-authentication-smtp-sender-password
        production-authentication-super-admin-password
        production-json-keys-app-master-key
        production-json-keys-postgres-dsn
        production-json-keys-postgres-password
        production-json-keys-postgres-backup-password
    )
    secret_inventory="$(gcloud secrets list --project="$MANAGEMENT_PROJECT_ID" \
        --format='value(name.basename())')"
    for secret_name in "${expected_secrets[@]}"; do
        if ! grep --fixed-strings --line-regexp --quiet \
            "$secret_name" <<<"$secret_inventory"; then
            fail "required Secret Manager container ${secret_name}"
        fi
        secret_policy="$(gcloud secrets get-iam-policy "$secret_name" \
            --project="$MANAGEMENT_PROJECT_ID" --format=json)"
        if ! jq --exit-status '
          all(.bindings[]?.members[]?;
            . != "allUsers" and . != "allAuthenticatedUsers"
          )
        ' <<<"$secret_policy" >/dev/null; then
            fail 'no public Secret Manager principals'
        fi
        case "$secret_name" in
            production-authentication-postgres-dsn)
                expected_secret_services='["agora-auth-initializer", "agora-authentication"]'
                ;;
            production-authentication-postgres-backup-password | production-json-keys-postgres-backup-password)
                expected_secret_services='["agora-backup", "agora-database-host"]'
                ;;
            production-authentication-postgres-password | production-json-keys-postgres-password)
                expected_secret_services='["agora-database-host"]'
                ;;
            production-authentication-smtp-sender-password)
                expected_secret_services='["agora-authentication"]'
                ;;
            production-authentication-super-admin-password)
                expected_secret_services='["agora-auth-initializer"]'
                ;;
            production-json-keys-app-master-key | production-json-keys-postgres-dsn)
                expected_secret_services='["agora-json-keys"]'
                ;;
        esac
        if ! jq --exit-status \
            --arg project "$WORKLOAD_PROJECT_ID" \
            --argjson expected "$expected_secret_services" '
          ($expected
            | map("serviceAccount:" + . + "@" + $project + ".iam.gserviceaccount.com")
            | sort
          ) as $expected_members
          | ([
              .bindings[]?
              | select(.role == "roles/secretmanager.secretAccessor")
              | .members[]?
              | select(startswith("serviceAccount:"))
            ] | sort) == $expected_members and
            ([
              .bindings[]? as $binding
              | $binding.members[]?
              | select(startswith("serviceAccount:"))
              | {role: $binding.role, member: .}
            ] | all(.[];
              .role == "roles/secretmanager.secretAccessor" and
              (.member as $member | $expected_members | index($member) != null)
            )
            )
        ' <<<"$secret_policy" >/dev/null; then
            fail "Secret Manager runtime allowlist for ${secret_name}"
        fi
    done
    pass 'required Secret Manager containers and runtime allowlists'

    backup_policy_json="$(gcloud storage buckets get-iam-policy \
        "gs://${BACKUP_BUCKET_NAME}" --format=json)"
    if ! jq --exit-status \
        --arg backup "serviceAccount:agora-backup@${WORKLOAD_PROJECT_ID}.iam.gserviceaccount.com" \
        --arg restore "serviceAccount:agora-restore@${WORKLOAD_PROJECT_ID}.iam.gserviceaccount.com" '
      def roles_for($member):
        [.bindings[]? | select(.members | index($member)) | .role] | sort;
      all(.bindings[]?.members[]?;
        . != "allUsers" and . != "allAuthenticatedUsers"
      ) and
      roles_for($backup) == ["roles/storage.objectCreator"] and
      roles_for($restore) == ["roles/storage.objectViewer"]
    ' <<<"$backup_policy_json" >/dev/null; then
        fail 'backup and restore bucket role separation'
    fi
    pass 'backup and restore bucket role separation'

    networks_json="$(gcloud compute networks list \
        --project="$WORKLOAD_PROJECT_ID" --format=json)"
    if ! jq --exit-status '
      length == 1 and
      .[0].name == "agora-production" and
      .[0].autoCreateSubnetworks == false and
      .[0].routingConfig.routingMode == "REGIONAL" and
      .[0].mtu == 1460
    ' <<<"$networks_json" >/dev/null; then
        fail 'single private production network'
    fi
    network_url="$(jq --raw-output '.[0].selfLink' <<<"$networks_json")"
    subnetworks_json="$(gcloud compute networks subnets list \
        --project="$WORKLOAD_PROJECT_ID" --network=agora-production --format=json)"
    if ! jq --exit-status --arg network "$network_url" '
      length == 1 and
      .[0].network == $network and
      .[0].privateIpGoogleAccess == true and
      .[0].stackType == "IPV4_ONLY" and
      (.[0].ipCidrRange | test("^10\\.[0-9]{1,3}\\.[0-9]{1,3}\\.0/24$"))
    ' <<<"$subnetworks_json" >/dev/null; then
        fail 'single private production subnet'
    fi
    production_subnet_cidr="$(jq --raw-output '.[0].ipCidrRange' \
        <<<"$subnetworks_json")"
    if ! is_private_24_cidr "$production_subnet_cidr"; then
        fail 'private production subnet CIDR'
    fi
    pass 'single private production network and subnet'

    routes_json="$(gcloud compute routes list \
        --project="$WORKLOAD_PROJECT_ID" --format=json)"
    if ! jq --exit-status --arg network "$network_url" --arg subnet "$production_subnet_cidr" '
      [.[] | select(.network == $network)] as $routes
      | ($routes | length == 3) and
        any($routes[]; .destRange == $subnet and .priority == 0) and
        ([ $routes[] | select(.name | startswith("restricted-google-")) | .destRange ] | sort) ==
          (["199.36.153.4/30", "34.126.0.0/18"] | sort) and
        all($routes[]; .destRange != "0.0.0.0/0")
    ' <<<"$routes_json" >/dev/null; then
        fail 'private production routes'
    fi
    pass 'private production routes'

    firewalls_json="$(gcloud compute firewall-rules list \
        --project="$WORKLOAD_PROJECT_ID" --format=json)"
    if ! jq --exit-status --arg network "$network_url" --arg subnet "$production_subnet_cidr" '
      [.[] | select(.network == $network)] as $rules
      | ([ $rules[].name ] | sort == ([
        "agora-allow-authentication-postgres-egress",
        "agora-allow-iap-ssh",
        "agora-allow-json-keys-postgres-egress",
        "agora-allow-postgres-ingress",
        "agora-allow-restricted-google-apis",
        "agora-deny-other-vpc-egress"
      ] | sort)) and
      all($rules[]; (.disabled // false) == false) and
      any($rules[];
        .name == "agora-deny-other-vpc-egress" and
        .direction == "EGRESS" and .priority == 1200 and
        .destinationRanges == ["0.0.0.0/0"] and
        ((.targetTags // []) | length == 0) and
        .denied == [{IPProtocol: "all"}]
      ) and
      any($rules[];
        .name == "agora-allow-postgres-ingress" and
        .sourceRanges == [$subnet] and
        .targetTags == ["agora-database"] and
        .direction == "INGRESS"
      ) and
      any($rules[];
        .name == "agora-allow-iap-ssh" and
        .sourceRanges == ["35.235.240.0/20"] and
        .targetTags == ["agora-database"] and
        .direction == "INGRESS"
      ) and
      all($rules[];
        if .direction == "INGRESS"
        then ((.sourceRanges // []) | index("0.0.0.0/0") == null)
        else true
        end
      )
    ' <<<"$firewalls_json" >/dev/null; then
        fail 'production firewall allowlist'
    fi
    pass 'production firewall allowlist'

    products_json="$(jq -n \
        --argjson routers "$(gcloud compute routers list \
            --project="$WORKLOAD_PROJECT_ID" --format=json)" \
        --argjson addresses "$(gcloud compute addresses list \
            --project="$WORKLOAD_PROJECT_ID" --format=json)" \
        --argjson forwarding "$(gcloud compute forwarding-rules list \
            --project="$WORKLOAD_PROJECT_ID" --format=json)" \
        '{routers: $routers, addresses: $addresses, forwarding: $forwarding}')"
    if ! jq --exit-status '
      (.routers | length == 0) and
      (.forwarding | length == 0) and
      all(.addresses[]?; .addressType != "EXTERNAL")
    ' <<<"$products_json" >/dev/null; then
        fail 'no public or fixed-cost network products'
    fi
    pass 'no public or fixed-cost network products'

    repositories_json="$(gcloud artifacts repositories list \
        --project="$WORKLOAD_PROJECT_ID" --location=all --format=json)"
    repository_json="$(jq --compact-output '
      [.[] | select(.name | endswith("/repositories/agora-production"))]
      | if length == 1 then .[0] else empty end
    ' <<<"$repositories_json")"
    if [ -z "$repository_json" ]; then
        fail 'single production registry'
    fi
    if ! jq --exit-status '
      .format == "DOCKER" and
      .mode == "STANDARD_REPOSITORY" and
      .dockerConfig.immutableTags == true
    ' <<<"$repository_json" >/dev/null; then
        fail 'immutable production registry'
    fi
    repository_location="$(jq --raw-output '
      .name | capture("/locations/(?<location>[^/]+)/repositories/").location
    ' <<<"$repository_json")"
    if ! [[ "$repository_location" =~ ^[a-z]+-[a-z]+[0-9]+$ ]]; then
        fail 'production registry location'
    fi
    repository_policy="$(gcloud artifacts repositories get-iam-policy agora-production \
        --project="$WORKLOAD_PROJECT_ID" --location="$repository_location" --format=json)"
    if ! jq --exit-status \
        --arg release "serviceAccount:infra-release@${MANAGEMENT_PROJECT_ID}.iam.gserviceaccount.com" \
        --arg recovery "serviceAccount:infra-recovery@${MANAGEMENT_PROJECT_ID}.iam.gserviceaccount.com" \
        --arg database "serviceAccount:agora-database-host@${WORKLOAD_PROJECT_ID}.iam.gserviceaccount.com" \
        --argjson initializers "$initializer_members" '
      all(.bindings[]?.members[]?;
        . != "allUsers" and . != "allAuthenticatedUsers"
      ) and
      ([
        .bindings[]?
        | select(.role == "roles/artifactregistry.writer")
        | .members[]?
      ] | sort) == [$release] and
      ([
        .bindings[]?
        | select(.role == "roles/artifactregistry.reader")
        | .members[]?
      ] | sort) == (($initializers + [$recovery, $database]) | sort) and
      all(.bindings[]?;
        .role == "roles/artifactregistry.reader" or
        .role == "roles/artifactregistry.writer"
      )
    ' <<<"$repository_policy" >/dev/null; then
        fail 'production registry access allowlist'
    fi
    pass 'immutable production registry and access allowlist'

    tag_keys_json="$(gcloud resource-manager tags keys list \
        --parent="projects/${project_number}" --format=json)"
    invocation_key="$(jq --raw-output '
      [.[] | select(.shortName == "agora-invocation") | .name]
      | if length == 1 then .[0] else empty end
    ' <<<"$tag_keys_json")"
    if ! [[ "$invocation_key" =~ ^tagKeys/[0-9]+$ ]]; then
        fail 'Cloud Run invocation tag key'
    fi
    tag_values_json="$(gcloud resource-manager tags values list \
        --parent="$invocation_key" --format=json)"
    if ! jq --exit-status '
      ([.[].shortName] | sort) ==
      (["initializer", "internal", "recovery", "release", "scheduled"] | sort) and
      all(.[].name; test("^tagValues/[0-9]+$"))
    ' <<<"$tag_values_json" >/dev/null; then
        fail 'Cloud Run invocation tag values'
    fi
    initializer_tag_value="$(jq --raw-output '
      [.[] | select(.shortName == "initializer") | .name]
      | if length == 1 then .[0] else empty end
    ' <<<"$tag_values_json")"
    initializer_tag_policy="$(gcloud resource-manager tags values get-iam-policy \
        "$initializer_tag_value" --format=json)"
    if ! jq --exit-status --argjson expected "$initializer_members" '
      all(.bindings[]?.members[]?;
        . != "allUsers" and . != "allAuthenticatedUsers"
      ) and
      all(.bindings[]?; .role == "roles/resourcemanager.tagUser") and
      ([
        .bindings[]?
        | select(.role == "roles/resourcemanager.tagUser")
        | .members[]?
      ] | sort == $expected)
    ' <<<"$initializer_tag_policy" >/dev/null; then
        fail 'human-only Authentication initializer tag'
    fi
    initializer_service_account_policy="$(gcloud iam service-accounts get-iam-policy \
        "agora-auth-initializer@${WORKLOAD_PROJECT_ID}.iam.gserviceaccount.com" \
        --project="$WORKLOAD_PROJECT_ID" --format=json)"
    if ! jq --exit-status --argjson expected "$initializer_members" '
      all(.bindings[]?.members[]?;
        . != "allUsers" and . != "allAuthenticatedUsers"
      ) and
      all(.bindings[]?; .role == "roles/iam.serviceAccountUser") and
      ([
        .bindings[]?
        | select(.role == "roles/iam.serviceAccountUser")
        | .members[]?
      ] | sort == $expected)
    ' <<<"$initializer_service_account_policy" >/dev/null; then
        fail 'human-only Authentication initializer identity'
    fi
    pass 'Cloud Run invocation tags'

    pass 'foundation audit complete'
}

audit_foundation
