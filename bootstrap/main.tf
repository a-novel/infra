provider "google" {
  project = var.management_project_id
  region  = var.region

  default_labels = local.labels
}

# Only service-agent creation needs the beta provider.
provider "google-beta" {
  project = var.management_project_id
  region  = var.region
}

data "google_project" "management" {
  project_id = var.management_project_id
}

locals {
  labels = {
    application = "agora"
    environment = "production"
    managed-by  = "opentofu"
    plane       = "management"
  }

  required_services = toset([
    "accesscontextmanager.googleapis.com",
    "billingbudgets.googleapis.com",
    "cloudbilling.googleapis.com",
    "cloudscheduler.googleapis.com",
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
    "workflowexecutions.googleapis.com",
    "workflows.googleapis.com",
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
        "deploy.yaml"        = "production"
        "roll-database.yaml" = "production"
        "recovery.yaml"      = "production"
      }
      pull_requests = null
    }
    downtime = {
      service_account_id = "infra-downtime"
      display_name       = "Infra downtime announcements"
      provider_id        = "github-downtime"
      workflows          = { "downtime.yaml" = null }
      pull_requests      = null
    }
    # Authentication trusts the visitor IP header its callers send, so no pull request may mint the
    # identity that calls it on a schedule.
    health = {
      service_account_id = "infra-health"
      display_name       = "Infra scheduled health check"
      provider_id        = "github-health"
      workflows          = { "drift.yaml" = null }
      pull_requests      = null
    }
    # The GitHub root applies from its own environment, apart from Google Cloud's production. It
    # reads its Deploy App keys, the governance secrets and its own state, and nothing in Google
    # Cloud.
    github = {
      service_account_id = "infra-github"
      display_name       = "Infra GitHub root deployment"
      provider_id        = "github-github"
      workflows = {
        "deploy.yaml" = "github"
        "sweep.yaml"  = "github"
      }
      pull_requests = null
    }
    # The GitHub root's drift check reads the Deploy App keys, so no pull request may mint it.
    drift = {
      service_account_id = "infra-drift"
      display_name       = "Infra GitHub root drift check"
      provider_id        = "github-drift"
      workflows          = { "drift.yaml" = null }
      pull_requests      = null
    }
    # The Grafana root applies from its own environment, apart from Google Cloud's production. It
    # reads its write tokens and its own state, and nothing else in Google Cloud.
    grafana = {
      service_account_id = "infra-grafana"
      display_name       = "Infra Grafana root deployment"
      provider_id        = "github-grafana"
      workflows          = { "deploy.yaml" = "grafana" }
      pull_requests      = null
    }
  }

  secret_definitions = merge({
    production-authentication-app-password = {
      contract = "POSTGRES_PASSWORD"
      purpose  = "Authentication application role password, for a login without superuser rights"
    }
    production-authentication-waitlist-secret = {
      contract = "WAITLIST_SECRET"
      purpose  = "Authentication invitation-list request signing key"
    }
    production-json-keys-app-master-key = {
      contract = "APP_MASTER_KEY"
      purpose  = "JSON Keys service application master key"
    }
    production-json-keys-app-password = {
      contract = "POSTGRES_PASSWORD"
      purpose  = "JSON Keys application role password, for a login without superuser rights"
    }
    production-genai-openai-api-key = {
      contract = "OPENAI_API_KEY"
      purpose  = "GenAI OpenAI API key, restricted to the Responses endpoints"
    }
    production-genai-app-password = {
      contract = "POSTGRES_PASSWORD"
      purpose  = "GenAI application role password, for a login without superuser rights"
    }
    production-downtime-discord-webhook = {
      contract = "DISCORD_WEBHOOK"
      purpose  = "Discord webhook of the public planned downtime channel"
    }
    production-github-dispatch-a-novel = {
      contract = "GITHUB_TOKEN"
      purpose  = "Fine-grained token that dispatches the a-novel/.github workflows"
    }
    production-github-dispatch-a-novel-kit = {
      contract = "GITHUB_TOKEN"
      purpose  = "Fine-grained token that dispatches the a-novel-kit/.github workflows"
    }
    production-grafana-plan-token = {
      contract = "GRAFANA_AUTH"
      purpose  = "Read-only Grafana token, with which pull requests and the drift check plan the Grafana root"
    }
    production-grafana-deploy-token = {
      contract = "GRAFANA_AUTH"
      purpose  = "Grafana token with which deploys apply the Grafana root"
    }
    production-grafana-cloud-plan-token = {
      contract = "GRAFANA_CLOUD_ACCESS_POLICY_TOKEN"
      purpose  = "Read-only Grafana Cloud token, with which pull requests and the drift check plan the Grafana root's Frontend Observability apps"
    }
    production-grafana-cloud-deploy-token = {
      contract = "GRAFANA_CLOUD_ACCESS_POLICY_TOKEN"
      purpose  = "Grafana Cloud token with which deploys apply the Grafana root's Frontend Observability apps"
    }
    production-alloy-push-token = {
      contract = "GRAFANA_CLOUD_ACCESS_POLICY_TOKEN"
      purpose  = "Grafana Cloud token with which Alloy pushes metrics, logs and traces"
    }
    }, { for secret, credential in local.pgbackrest_tls : secret => {
      contract = credential.contract
      purpose  = credential.purpose
  } }, local.github_root_secrets)

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
