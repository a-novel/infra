#!/bin/bash

# Provides service and IAM responses for boundary-focused foundation audits.

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

cloud_run_policy='{
  "bindings": [
    {
      "role": "projects/workload-project-prod/roles/authenticationInitializerDeployer",
      "members": ["user:operator@example.com"]
    },
    {
      "role": "roles/compute.osAdminLogin",
      "members": ["user:operator@example.com"]
    },
    {
      "role": "roles/compute.viewer",
      "members": ["user:operator@example.com"]
    },
    {
      "role": "roles/iap.tunnelResourceAccessor",
      "members": ["user:operator@example.com"],
      "condition": {
        "title": "DatabaseIAPSSHOnly",
        "expression": "destination.port == 22"
      }
    },
    {
      "role": "roles/logging.viewer",
      "members": ["user:operator@example.com"]
    },
    {
      "role": "roles/monitoring.alertPolicyViewer",
      "members": ["user:operator@example.com"]
    },
    {
      "role": "roles/serviceusage.serviceUsageConsumer",
      "members": ["user:operator@example.com"]
    },
    {
      "role": "roles/run.jobsExecutor",
      "members": ["user:operator@example.com"],
      "condition": {
        "title": "AuthenticationInitializerOnly",
        "expression": "resource.matchTagId(\"tagKeys/1\", \"tagValues/1\")"
      }
    },
    {
      "role": "roles/run.jobsExecutor",
      "members": ["serviceAccount:infra-release@management-project-prod.iam.gserviceaccount.com"],
      "condition": {
        "title": "ReleaseTaggedCloudRunOnly",
        "expression": "resource.matchTagId(\"tagKeys/1\", \"tagValues/2\")"
      }
    },
    {
      "role": "roles/run.jobsExecutor",
      "members": ["serviceAccount:agora-scheduler-invoker@workload-project-prod.iam.gserviceaccount.com"],
      "condition": {
        "title": "ScheduledCloudRunOnly",
        "expression": "resource.matchTagId(\"tagKeys/1\", \"tagValues/3\")"
      }
    },
    {
      "role": "roles/run.serviceAgent",
      "members": ["serviceAccount:service-123456789012@serverless-robot-prod.iam.gserviceaccount.com"]
    },
    {
      "role": "roles/run.servicesInvoker",
      "members": ["serviceAccount:agora-authentication@workload-project-prod.iam.gserviceaccount.com"],
      "condition": {
        "title": "InternalCloudRunOnly",
        "expression": "resource.matchTagId(\"tagKeys/1\", \"tagValues/4\")"
      }
    }
  ]
}'

case "$*" in
    "projects describe workload-project-prod --format=json")
        printf '%s\n' '{"projectId":"workload-project-prod","projectNumber":"123456789012","lifecycleState":"ACTIVE","labels":{"application":"agora","environment":"production","managed-by":"opentofu","plane":"workload","recovery":"false"}}'
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
        case "${FAKE_FOUNDATION_IAM_MODE:-stop}" in
            valid-service-agent)
                printf '%s\n' "$cloud_run_policy"
                ;;
            wrong-service-agent)
                jq --compact-output '
                  (.bindings[] | select(.role == "roles/run.serviceAgent").members) =
                  ["serviceAccount:unexpected@example.com"]
                ' <<<"$cloud_run_policy"
                ;;
            unexpected-run-role)
                jq --compact-output '
                  .bindings += [{
                    role: "roles/run.admin",
                    members: ["user:operator@example.com"]
                  }]
                ' <<<"$cloud_run_policy"
                ;;
            missing-operator-api-access)
                jq --compact-output '
                  del(.bindings[] |
                    select(.role == "roles/serviceusage.serviceUsageConsumer")
                  )
                ' <<<"$cloud_run_policy"
                ;;
            stop)
                exit 64
                ;;
            *)
                exit 64
                ;;
        esac
        ;;
    *)
        exit 64
        ;;
esac
