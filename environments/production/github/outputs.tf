# What secret sync copies after each apply: no value, only which Secret Manager version each
# repository's governance environment receives, and the Deploy App that writes it.
output "secret_sync" {
  description = "Per organization: the Deploy App and its key, each governance secret's pinned version, and the secrets each repository's governance environment holds."
  value = {
    for owner, organization in var.organizations : owner => {
      project = var.management_project_id
      app = {
        id              = var.apps[owner].deploy.id
        installation_id = var.apps[owner].deploy.installation_id
        key             = { secret = "production-github-deploy-key-${owner}", version = var.apps[owner].deploy.key_version }
      }
      secrets = {
        for name, version in organization.governance_secrets : name => {
          secret  = "production-github-governance-${owner}-${lower(replace(name, "_", "-"))}"
          version = version
        }
      }
      repositories = { a-novel = module.a_novel.governance_secrets, a-novel-kit = module.a_novel_kit.governance_secrets }[owner]
    }
  }
}
