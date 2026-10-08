import {
  to = module.private_runtime.google_service_account.runtime
  id = "projects/a-novel-production-prod/serviceAccounts/agora-authentication-private@a-novel-production-prod.iam.gserviceaccount.com"
}

import {
  to = module.private_runtime.google_service_account_iam_member.deployer
  id = "projects/a-novel-production-prod/serviceAccounts/agora-authentication-private@a-novel-production-prod.iam.gserviceaccount.com roles/iam.serviceAccountUser serviceAccount:infra-foundation@a-novel-management-prod.iam.gserviceaccount.com"
}

import {
  to = module.private_runtime.google_project_iam_member.telemetry["roles/serviceusage.serviceUsageConsumer"]
  id = "a-novel-production-prod roles/serviceusage.serviceUsageConsumer serviceAccount:agora-authentication-private@a-novel-production-prod.iam.gserviceaccount.com"
}

import {
  to = module.private_runtime.google_project_iam_member.telemetry["roles/telemetry.writer"]
  id = "a-novel-production-prod roles/telemetry.writer serviceAccount:agora-authentication-private@a-novel-production-prod.iam.gserviceaccount.com"
}

import {
  to = module.private_runtime.google_secret_manager_secret_iam_member.runtime["production-authentication-postgres-password"]
  id = "projects/a-novel-management-prod/secrets/production-authentication-postgres-password roles/secretmanager.secretAccessor serviceAccount:agora-authentication-private@a-novel-production-prod.iam.gserviceaccount.com"
}

import {
  to = module.private_runtime.google_artifact_registry_repository.images["production"]
  id = "projects/a-novel-production-prod/locations/europe-west1/repositories/agora-authentication-private-production"
}

import {
  to = module.private_runtime.google_artifact_registry_repository.images["tooling"]
  id = "projects/a-novel-production-prod/locations/europe-west1/repositories/agora-authentication-private-tooling"
}

import {
  to = module.private_runtime.google_monitoring_notification_channel.operations
  id = "projects/a-novel-production-prod/notificationChannels/13728651139067489556"
}

import {
  to = module.backups.google_service_account.repository
  id = "projects/a-novel-production-prod/serviceAccounts/agora-pgbr-authentication@a-novel-production-prod.iam.gserviceaccount.com"
}

import {
  to = module.backups.google_service_account_iam_member.deployer
  id = "projects/a-novel-production-prod/serviceAccounts/agora-pgbr-authentication@a-novel-production-prod.iam.gserviceaccount.com roles/iam.serviceAccountUser serviceAccount:infra-foundation@a-novel-management-prod.iam.gserviceaccount.com"
}

import {
  to = module.backups.google_artifact_registry_repository_iam_member.readers["production/repository"]
  id = "projects/a-novel-production-prod/locations/europe-west1/repositories/agora-authentication-private-production roles/artifactregistry.reader serviceAccount:agora-pgbr-authentication@a-novel-production-prod.iam.gserviceaccount.com"
}

import {
  to = module.backups.google_artifact_registry_repository_iam_member.readers["tooling/repository"]
  id = "projects/a-novel-production-prod/locations/europe-west1/repositories/agora-authentication-private-tooling roles/artifactregistry.reader serviceAccount:agora-pgbr-authentication@a-novel-production-prod.iam.gserviceaccount.com"
}

import {
  to = module.backups.google_artifact_registry_repository_iam_member.readers["production/database"]
  id = "projects/a-novel-production-prod/locations/europe-west1/repositories/agora-authentication-private-production roles/artifactregistry.reader serviceAccount:agora-auth-database@a-novel-production-prod.iam.gserviceaccount.com"
}

import {
  to = module.backups.google_artifact_registry_repository_iam_member.readers["tooling/database"]
  id = "projects/a-novel-production-prod/locations/europe-west1/repositories/agora-authentication-private-tooling roles/artifactregistry.reader serviceAccount:agora-auth-database@a-novel-production-prod.iam.gserviceaccount.com"
}

import {
  to = module.backups.google_compute_instance.repository
  id = "projects/a-novel-production-prod/zones/europe-west1-d/instances/agora-pgbackrest-authentication"
}

import {
  to = module.backups.google_logging_metric.backup_success
  id = "a-novel-production-prod agora_authentication_backup_success"
}

import {
  to = module.backups.google_monitoring_alert_policy.backup_failure
  id = "projects/a-novel-production-prod/alertPolicies/4925363407742152615"
}

import {
  to = module.backups.google_monitoring_alert_policy.backup_health["backup"]
  id = "projects/a-novel-production-prod/alertPolicies/15028473824330191239"
}

import {
  to = module.backups.google_monitoring_alert_policy.backup_health["check"]
  id = "projects/a-novel-production-prod/alertPolicies/6654092061063859687"
}

import {
  to = module.backups.google_monitoring_alert_policy.backup_health["disk"]
  id = "projects/a-novel-production-prod/alertPolicies/17996407744505507641"
}

import {
  to = module.backups.google_monitoring_alert_policy.backup_health["full"]
  id = "projects/a-novel-production-prod/alertPolicies/6654092061063857921"
}

import {
  to = google_artifact_registry_repository_iam_member.retired_private_recovery_readers["production"]
  id = "projects/a-novel-production-prod/locations/europe-west1/repositories/agora-authentication-private-production roles/artifactregistry.reader serviceAccount:infra-recovery@a-novel-management-prod.iam.gserviceaccount.com"
}

import {
  to = google_artifact_registry_repository_iam_member.retired_private_recovery_readers["tooling"]
  id = "projects/a-novel-production-prod/locations/europe-west1/repositories/agora-authentication-private-tooling roles/artifactregistry.reader serviceAccount:infra-recovery@a-novel-management-prod.iam.gserviceaccount.com"
}

import {
  to = google_project_iam_member.retired_private_repository_ssh
  id = "a-novel-production-prod roles/iap.tunnelResourceAccessor serviceAccount:infra-foundation@a-novel-management-prod.iam.gserviceaccount.com RepositoryMaintenanceSSH-authentication"
}

import {
  to = module.api_runtime.google_service_account.runtime
  id = "projects/a-novel-public-api-prod/serviceAccounts/agora-authentication-api@a-novel-public-api-prod.iam.gserviceaccount.com"
}

import {
  to = module.api_runtime.google_service_account_iam_member.deployer
  id = "projects/a-novel-public-api-prod/serviceAccounts/agora-authentication-api@a-novel-public-api-prod.iam.gserviceaccount.com roles/iam.serviceAccountUser serviceAccount:infra-foundation@a-novel-management-prod.iam.gserviceaccount.com"
}

import {
  to = module.api_runtime.google_project_iam_member.telemetry["roles/serviceusage.serviceUsageConsumer"]
  id = "a-novel-public-api-prod roles/serviceusage.serviceUsageConsumer serviceAccount:agora-authentication-api@a-novel-public-api-prod.iam.gserviceaccount.com"
}

import {
  to = module.api_runtime.google_project_iam_member.telemetry["roles/telemetry.writer"]
  id = "a-novel-public-api-prod roles/telemetry.writer serviceAccount:agora-authentication-api@a-novel-public-api-prod.iam.gserviceaccount.com"
}

import {
  to = module.api_runtime.google_secret_manager_secret_iam_member.runtime["production-authentication-postgres-password"]
  id = "projects/a-novel-management-prod/secrets/production-authentication-postgres-password roles/secretmanager.secretAccessor serviceAccount:agora-authentication-api@a-novel-public-api-prod.iam.gserviceaccount.com"
}

import {
  to = module.api_runtime.google_secret_manager_secret_iam_member.runtime["production-authentication-smtp-sender-password"]
  id = "projects/a-novel-management-prod/secrets/production-authentication-smtp-sender-password roles/secretmanager.secretAccessor serviceAccount:agora-authentication-api@a-novel-public-api-prod.iam.gserviceaccount.com"
}

import {
  to = module.api_runtime.google_artifact_registry_repository.images["production"]
  id = "projects/a-novel-public-api-prod/locations/europe-west1/repositories/agora-authentication-api-production"
}

import {
  to = module.api_runtime.google_artifact_registry_repository.images["tooling"]
  id = "projects/a-novel-public-api-prod/locations/europe-west1/repositories/agora-authentication-api-tooling"
}

import {
  to = module.api_runtime.google_monitoring_notification_channel.operations
  id = "projects/a-novel-public-api-prod/notificationChannels/12699493212956278887"
}

import {
  to = google_artifact_registry_repository_iam_member.retired_api_recovery_readers["production"]
  id = "projects/a-novel-public-api-prod/locations/europe-west1/repositories/agora-authentication-api-production roles/artifactregistry.reader serviceAccount:infra-recovery@a-novel-management-prod.iam.gserviceaccount.com"
}

import {
  to = google_artifact_registry_repository_iam_member.retired_api_recovery_readers["tooling"]
  id = "projects/a-novel-public-api-prod/locations/europe-west1/repositories/agora-authentication-api-tooling roles/artifactregistry.reader serviceAccount:infra-recovery@a-novel-management-prod.iam.gserviceaccount.com"
}

import {
  to = google_cloud_run_v2_service_iam_member.json_keys_invoker
  id = "projects/a-novel-production-prod/locations/europe-west1/services/agora-json-keys-grpc roles/run.servicesInvoker serviceAccount:agora-authentication-api@a-novel-public-api-prod.iam.gserviceaccount.com"
}

import {
  to = google_monitoring_alert_policy.rest_error_rate
  id = "projects/a-novel-public-api-prod/alertPolicies/9427648171111692324"
}

import {
  to = google_secret_manager_secret_iam_member.retired_secret_viewers["production-authentication-postgres-password"]
  id = "projects/a-novel-management-prod/secrets/production-authentication-postgres-password roles/secretmanager.viewer serviceAccount:infra-foundation@a-novel-management-prod.iam.gserviceaccount.com"
}

import {
  to = google_secret_manager_secret_iam_member.retired_secret_viewers["production-authentication-smtp-sender-password"]
  id = "projects/a-novel-management-prod/secrets/production-authentication-smtp-sender-password roles/secretmanager.viewer serviceAccount:infra-foundation@a-novel-management-prod.iam.gserviceaccount.com"
}

import {
  to = google_cloud_run_v2_job.migrations
  id = "projects/a-novel-production-prod/locations/europe-west1/jobs/agora-authentication-migrations"
}

import {
  to = google_cloud_run_v2_service.rest
  id = "projects/a-novel-public-api-prod/locations/europe-west1/services/agora-authentication-rest"
}
