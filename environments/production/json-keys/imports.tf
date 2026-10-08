import {
  to = module.runtime.google_service_account.runtime
  id = "projects/a-novel-production-prod/serviceAccounts/agora-json-keys-private@a-novel-production-prod.iam.gserviceaccount.com"
}

import {
  to = module.runtime.google_service_account_iam_member.deployer
  id = "projects/a-novel-production-prod/serviceAccounts/agora-json-keys-private@a-novel-production-prod.iam.gserviceaccount.com roles/iam.serviceAccountUser serviceAccount:infra-foundation@a-novel-management-prod.iam.gserviceaccount.com"
}

import {
  to = module.runtime.google_project_iam_member.telemetry["roles/serviceusage.serviceUsageConsumer"]
  id = "a-novel-production-prod roles/serviceusage.serviceUsageConsumer serviceAccount:agora-json-keys-private@a-novel-production-prod.iam.gserviceaccount.com"
}

import {
  to = module.runtime.google_project_iam_member.telemetry["roles/telemetry.writer"]
  id = "a-novel-production-prod roles/telemetry.writer serviceAccount:agora-json-keys-private@a-novel-production-prod.iam.gserviceaccount.com"
}

import {
  to = module.runtime.google_secret_manager_secret_iam_member.runtime["production-json-keys-app-master-key"]
  id = "projects/a-novel-management-prod/secrets/production-json-keys-app-master-key roles/secretmanager.secretAccessor serviceAccount:agora-json-keys-private@a-novel-production-prod.iam.gserviceaccount.com"
}

import {
  to = module.runtime.google_secret_manager_secret_iam_member.runtime["production-json-keys-postgres-password"]
  id = "projects/a-novel-management-prod/secrets/production-json-keys-postgres-password roles/secretmanager.secretAccessor serviceAccount:agora-json-keys-private@a-novel-production-prod.iam.gserviceaccount.com"
}

import {
  to = module.runtime.google_artifact_registry_repository.images["production"]
  id = "projects/a-novel-production-prod/locations/europe-west1/repositories/agora-json-keys-private-production"
}

import {
  to = module.runtime.google_artifact_registry_repository.images["tooling"]
  id = "projects/a-novel-production-prod/locations/europe-west1/repositories/agora-json-keys-private-tooling"
}

import {
  to = module.runtime.google_monitoring_notification_channel.operations
  id = "projects/a-novel-production-prod/notificationChannels/3450427144882081004"
}

import {
  to = module.backups.google_service_account.repository
  id = "projects/a-novel-production-prod/serviceAccounts/agora-pgbr-json-keys@a-novel-production-prod.iam.gserviceaccount.com"
}

import {
  to = module.backups.google_service_account_iam_member.deployer
  id = "projects/a-novel-production-prod/serviceAccounts/agora-pgbr-json-keys@a-novel-production-prod.iam.gserviceaccount.com roles/iam.serviceAccountUser serviceAccount:infra-foundation@a-novel-management-prod.iam.gserviceaccount.com"
}

import {
  to = module.backups.google_artifact_registry_repository_iam_member.readers["production/repository"]
  id = "projects/a-novel-production-prod/locations/europe-west1/repositories/agora-json-keys-private-production roles/artifactregistry.reader serviceAccount:agora-pgbr-json-keys@a-novel-production-prod.iam.gserviceaccount.com"
}

import {
  to = module.backups.google_artifact_registry_repository_iam_member.readers["tooling/repository"]
  id = "projects/a-novel-production-prod/locations/europe-west1/repositories/agora-json-keys-private-tooling roles/artifactregistry.reader serviceAccount:agora-pgbr-json-keys@a-novel-production-prod.iam.gserviceaccount.com"
}

import {
  to = module.backups.google_artifact_registry_repository_iam_member.readers["production/database"]
  id = "projects/a-novel-production-prod/locations/europe-west1/repositories/agora-json-keys-private-production roles/artifactregistry.reader serviceAccount:agora-json-keys-database@a-novel-production-prod.iam.gserviceaccount.com"
}

import {
  to = module.backups.google_artifact_registry_repository_iam_member.readers["tooling/database"]
  id = "projects/a-novel-production-prod/locations/europe-west1/repositories/agora-json-keys-private-tooling roles/artifactregistry.reader serviceAccount:agora-json-keys-database@a-novel-production-prod.iam.gserviceaccount.com"
}

import {
  to = module.backups.google_compute_instance.repository
  id = "projects/a-novel-production-prod/zones/europe-west1-d/instances/agora-pgbackrest-json-keys"
}

import {
  to = module.backups.google_logging_metric.backup_success
  id = "a-novel-production-prod agora_json-keys_backup_success"
}

import {
  to = module.backups.google_monitoring_alert_policy.backup_failure
  id = "projects/a-novel-production-prod/alertPolicies/6757519884198592832"
}

import {
  to = module.backups.google_monitoring_alert_policy.backup_health["backup"]
  id = "projects/a-novel-production-prod/alertPolicies/4497670034526804803"
}

import {
  to = module.backups.google_monitoring_alert_policy.backup_health["check"]
  id = "projects/a-novel-production-prod/alertPolicies/9981020420416918531"
}

import {
  to = module.backups.google_monitoring_alert_policy.backup_health["disk"]
  id = "projects/a-novel-production-prod/alertPolicies/3948669399838854785"
}

import {
  to = module.backups.google_monitoring_alert_policy.backup_health["full"]
  id = "projects/a-novel-production-prod/alertPolicies/10389804817729716435"
}

import {
  to = google_artifact_registry_repository_iam_member.retired_recovery_readers["production"]
  id = "projects/a-novel-production-prod/locations/europe-west1/repositories/agora-json-keys-private-production roles/artifactregistry.reader serviceAccount:infra-recovery@a-novel-management-prod.iam.gserviceaccount.com"
}

import {
  to = google_artifact_registry_repository_iam_member.retired_recovery_readers["tooling"]
  id = "projects/a-novel-production-prod/locations/europe-west1/repositories/agora-json-keys-private-tooling roles/artifactregistry.reader serviceAccount:infra-recovery@a-novel-management-prod.iam.gserviceaccount.com"
}

import {
  to = google_artifact_registry_repository_iam_member.retired_release_writer
  id = "projects/a-novel-production-prod/locations/europe-west1/repositories/agora-json-keys-private-production roles/artifactregistry.writer serviceAccount:infra-json-keys-private@a-novel-production-prod.iam.gserviceaccount.com"
}

import {
  to = google_project_iam_member.retired_repository_ssh
  id = "a-novel-production-prod roles/iap.tunnelResourceAccessor serviceAccount:infra-foundation@a-novel-management-prod.iam.gserviceaccount.com RepositoryMaintenanceSSH-json-keys"
}

import {
  to = google_cloud_run_v2_service_iam_member.smoke_invoker
  id = "projects/a-novel-production-prod/locations/europe-west1/services/agora-json-keys-grpc roles/run.servicesInvoker serviceAccount:agora-json-keys-private@a-novel-production-prod.iam.gserviceaccount.com"
}

import {
  to = google_cloud_run_v2_job.application["migrations"]
  id = "projects/a-novel-production-prod/locations/europe-west1/jobs/agora-json-keys-migrations"
}

import {
  to = google_cloud_run_v2_job.application["rotatekeys"]
  id = "projects/a-novel-production-prod/locations/europe-west1/jobs/agora-json-keys-rotatekeys"
}

import {
  to = google_cloud_run_v2_job.smoke
  id = "projects/a-novel-production-prod/locations/europe-west1/jobs/agora-json-keys-smoke"
}

import {
  to = google_cloud_run_v2_service.grpc
  id = "projects/a-novel-production-prod/locations/europe-west1/services/agora-json-keys-grpc"
}
