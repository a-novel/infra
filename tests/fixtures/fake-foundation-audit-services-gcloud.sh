#!/bin/bash

# Stops a foundation audit immediately after its enabled-service boundary.

set -euo pipefail

CALLS_FILE="${FAKE_FOUNDATION_CALLS:?FAKE_FOUNDATION_CALLS is required}"
printf '%s\n' "$*" >>"$CALLS_FILE"

required_services='[
  {"config":{"name":"artifactregistry.googleapis.com"}},
  {"config":{"name":"cloudquotas.googleapis.com"}},
  {"config":{"name":"cloudresourcemanager.googleapis.com"}},
  {"config":{"name":"cloudscheduler.googleapis.com"}},
  {"config":{"name":"compute.googleapis.com"}},
  {"config":{"name":"dns.googleapis.com"}},
  {"config":{"name":"iam.googleapis.com"}},
  {"config":{"name":"iap.googleapis.com"}},
  {"config":{"name":"logging.googleapis.com"}},
  {"config":{"name":"monitoring.googleapis.com"}},
  {"config":{"name":"oslogin.googleapis.com"}},
  {"config":{"name":"run.googleapis.com"}},
  {"config":{"name":"serviceusage.googleapis.com"}}
]'

case "$*" in
    "projects describe workload-project-prod --format=json")
        printf '%s\n' '{"projectId":"workload-project-prod","lifecycleState":"ACTIVE","labels":{"application":"agora","environment":"production","managed-by":"opentofu","plane":"workload","recovery":"false"}}'
        ;;
    "billing projects describe workload-project-prod --format=json")
        printf '%s\n' '{"billingEnabled":true}'
        ;;
    "services list --enabled --project=workload-project-prod --format=json")
        case "${FAKE_FOUNDATION_SERVICE_MODE:-allowed}" in
            allowed)
                jq --compact-output '. + [
                  {"config":{"name":"cloudtrace.googleapis.com"}},
                  {"config":{"name":"containerregistry.googleapis.com"}},
                  {"config":{"name":"iamcredentials.googleapis.com"}},
                  {"config":{"name":"pubsub.googleapis.com"}},
                  {"config":{"name":"storage-api.googleapis.com"}},
                  {"config":{"name":"storage-component.googleapis.com"}},
                  {"config":{"name":"telemetry.googleapis.com"}}
                ]' <<<"$required_services"
                ;;
            missing)
                jq --compact-output \
                    'map(select(.config.name != "run.googleapis.com"))' \
                    <<<"$required_services"
                ;;
            unexpected)
                jq --compact-output \
                    '. + [{"config":{"name":"unknown.googleapis.com"}}]' \
                    <<<"$required_services"
                ;;
            *)
                exit 64
                ;;
        esac
        ;;
    "projects get-iam-policy workload-project-prod --format=json")
        exit 64
        ;;
    *)
        exit 64
        ;;
esac
