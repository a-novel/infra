provider "google" {
  project = var.management_project_id
  region  = var.region

  default_labels = local.labels
}

data "google_project" "management" {
  project_id = var.management_project_id
}

locals {
  root_name = "bootstrap"

  labels = {
    application = "agora"
    environment = "production"
    managed-by  = "opentofu"
    plane       = "management"
  }

  required_services = toset([
    "billingbudgets.googleapis.com",
    "cloudbilling.googleapis.com",
    "cloudquotas.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "logging.googleapis.com",
    "orgpolicy.googleapis.com",
    "secretmanager.googleapis.com",
    "serviceusage.googleapis.com",
    "storage.googleapis.com",
    "sts.googleapis.com",
  ])

  github = {
    owner_id      = "131281268"
    repository    = "a-novel/infra"
    repository_id = "1344262359"
    ref           = "refs/heads/master"
  }

  trust_boundaries = {
    plan = {
      service_account_id = "infra-plan"
      display_name       = "Infra plan and drift"
      provider_id        = "github-plan"
      workflow_filename  = "drift.yaml"
      environment        = null
    }
    foundation = {
      service_account_id = "infra-foundation"
      display_name       = "Infra foundation deployment"
      provider_id        = "github-foundation"
      workflow_filename  = "foundation.yaml"
      environment        = "production-foundation"
    }
    release = {
      service_account_id = "infra-release"
      display_name       = "Infra application release"
      provider_id        = "github-release"
      workflow_filename  = "release.yaml"
      environment        = "production-release"
    }
    recovery = {
      service_account_id = "infra-recovery"
      display_name       = "Infra disaster recovery"
      provider_id        = "github-recovery"
      workflow_filename  = "recovery.yaml"
      environment        = "production-recovery"
    }
  }

  secret_definitions = {
    production-authentication-postgres-dsn = {
      contract = "POSTGRES_DSN"
      purpose  = "Authentication service PostgreSQL connection string"
    }
    production-authentication-postgres-password = {
      contract = "POSTGRES_PASSWORD"
      purpose  = "Authentication database owner password"
    }
    production-authentication-postgres-backup-password = {
      contract = "POSTGRES_BACKUP_PASSWORD"
      purpose  = "Authentication database read-only backup password"
    }
    production-authentication-smtp-sender-password = {
      contract = "SMTP_SENDER_PASSWORD"
      purpose  = "Authentication service production SMTP credential"
    }
    production-authentication-super-admin-password = {
      contract = "SUPER_ADMIN_PASSWORD"
      purpose  = "Authentication bootstrap administrator password"
    }
    production-json-keys-app-master-key = {
      contract = "APP_MASTER_KEY"
      purpose  = "JSON Keys service application master key"
    }
    production-json-keys-postgres-dsn = {
      contract = "POSTGRES_DSN"
      purpose  = "JSON Keys service PostgreSQL connection string"
    }
    production-json-keys-postgres-password = {
      contract = "POSTGRES_PASSWORD"
      purpose  = "JSON Keys database owner password"
    }
    production-json-keys-postgres-backup-password = {
      contract = "POSTGRES_BACKUP_PASSWORD"
      purpose  = "JSON Keys database read-only backup password"
    }
  }

  audited_services = toset([
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "secretmanager.googleapis.com",
    "storage.googleapis.com",
    "sts.googleapis.com",
  ])
}

resource "google_project_service" "management" {
  for_each = local.required_services

  project = var.management_project_id
  service = each.value

  disable_dependent_services = false
  disable_on_destroy         = false
}
