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
    "drive.googleapis.com",
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

  # Each boundary trusts exact master workflows, keyed to the GitHub
  # environment they must run in (null for none). Plan also trusts pull requests
  # from this repository; GitHub never issues OIDC tokens to fork pull requests.
  trust_boundaries = {
    plan = {
      service_account_id = "infra-plan"
      display_name       = "Infra plan and drift"
      provider_id        = "github-plan"
      workflows          = { "drift.yaml" = null }
      pull_requests      = "main.yaml"
    }
    foundation = {
      service_account_id = "infra-foundation"
      display_name       = "Infra foundation deployment"
      provider_id        = "github-foundation"
      workflows = {
        "deploy.yaml"   = "production"
        "recovery.yaml" = "production"
      }
      pull_requests = null
    }
    recovery = {
      service_account_id = "infra-recovery"
      display_name       = "Infra disaster recovery"
      provider_id        = "github-recovery"
      workflows          = { "recovery.yaml" = "production-recovery" }
      pull_requests      = null
    }
  }

  secret_definitions = merge({
    production-authentication-postgres-password = {
      contract = "POSTGRES_PASSWORD"
      purpose  = "Authentication database owner password"
    }
    production-authentication-smtp-sender-password = {
      contract = "SMTP_SENDER_PASSWORD"
      purpose  = "Authentication service production SMTP credential"
    }
    production-authentication-super-admin-password = {
      contract = "SUPER_ADMIN_PASSWORD"
      purpose  = "Authentication bootstrap administrator password"
    }
    production-authentication-waitlist-secret = {
      contract = "WAITLIST_SECRET"
      purpose  = "Authentication invitation-list request signing key"
    }
    production-json-keys-app-master-key = {
      contract = "APP_MASTER_KEY"
      purpose  = "JSON Keys service application master key"
    }
    production-json-keys-postgres-password = {
      contract = "POSTGRES_PASSWORD"
      purpose  = "JSON Keys database owner password"
    }
    }, { for secret, credential in local.pgbackrest_tls : secret => {
      contract = credential.contract
      purpose  = credential.purpose
  } })

  audited_services = toset([
    # Service Account Credentials inherits IAM's Data Access configuration and
    # rejects a separate service-level audit policy.
    "iam.googleapis.com",
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
