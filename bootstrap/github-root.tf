# The GitHub root manages each organization's repository config through two GitHub Apps
# (a-novel/.github#534), and reads their keys at plan time, as the Sentry and Grafana roots read
# their tokens. Pull requests plan with the plan identity, which may read only the read-only Plan App
# keys. GitHub shows a ruleset's bypass list only to an App that can change it, so the drift check
# plans with the Deploy App keys, through an identity no pull request can mint.
locals {
  github_root_owners = toset(["a-novel", "a-novel-kit"])

  # The privileged secrets of each organization's governance environments. Only deploys read them,
  # to copy them into the repositories whose workflows name them.
  github_governance_secrets = {
    AGENT_BOT_PRIVATE_KEY      = "Private key of the organization's Agent App"
    DEPENDENCY_BOT_PRIVATE_KEY = "Private key of the organization's Dependencies App"
    BWS_READ_TOKEN             = "Bitwarden token with which notify.yaml maps GitHub accounts to Discord users"
  }

  github_root_secrets = merge(
    { for pair in setproduct(local.github_root_owners, ["plan", "deploy"]) : "production-github-${pair[1]}-key-${pair[0]}" => {
      contract = "GITHUB_APP_PRIVATE_KEY"
      purpose = pair[1] == "plan" ? (
        "Private key of the ${pair[0]} Plan App, read-only, with which pull requests plan the GitHub root"
        ) : (
        "Private key of the ${pair[0]} Deploy App, with which deploys apply the GitHub root and the drift check plans it"
      )
    } },
    # The contract is the secret's name in GitHub.
    { for pair in setproduct(local.github_root_owners, keys(local.github_governance_secrets)) :
      "production-github-governance-${pair[0]}-${lower(replace(pair[1], "_", "-"))}" => {
        contract = pair[1]
        purpose  = "${local.github_governance_secrets[pair[1]]}, copied into the ${pair[0]} governance environments"
      }
    },
  )

  github_root_readers = {
    plan   = [for owner in local.github_root_owners : "production-github-plan-key-${owner}"]
    drift  = [for owner in local.github_root_owners : "production-github-deploy-key-${owner}"]
    github = [for secret in keys(local.github_root_secrets) : secret if !startswith(secret, "production-github-plan-key-")]
  }
}

resource "google_secret_manager_secret_iam_member" "github_root" {
  for_each = merge([for boundary, secrets in local.github_root_readers : {
    for secret in secrets : "${boundary}:${secret}" => { boundary = boundary, secret = secret }
  }]...)

  project   = var.management_project_id
  secret_id = google_secret_manager_secret.application[each.value.secret].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.automation[each.value.boundary].member
}

# The provider reads a key's version metadata before its payload. The plan identity holds a viewer
# role on the whole project; the GitHub root's deploy and drift identities hold one on their keys
# alone.
resource "google_secret_manager_secret_iam_member" "github_root_metadata" {
  for_each = merge([for boundary in ["github", "drift"] : {
    for secret in local.github_root_readers[boundary] : "${boundary}:${secret}" => { boundary = boundary, secret = secret }
  }]...)

  project   = var.management_project_id
  secret_id = google_secret_manager_secret.application[each.value.secret].secret_id
  role      = "roles/secretmanager.viewer"
  member    = google_service_account.automation[each.value.boundary].member
}

# The GitHub root's deploys write its state and lock under github/ alone. Listing the bucket shows
# object names, never their content.
resource "google_storage_bucket_iam_member" "github_state" {
  bucket = google_storage_bucket.state.name
  role   = "roles/storage.objectAdmin"
  member = google_service_account.automation["github"].member

  condition {
    title      = "github-root-state"
    expression = "resource.type == \"storage.googleapis.com/Bucket\" || resource.name.startsWith(\"projects/_/buckets/${google_storage_bucket.state.name}/objects/github/\")"
  }
}

# State holds no secret values, so the drift identity reads it as the plan identity does, without
# creating .tflock objects.
resource "google_storage_bucket_iam_member" "drift_state" {
  bucket = google_storage_bucket.state.name
  role   = "roles/storage.objectViewer"
  member = google_service_account.automation["drift"].member
}
