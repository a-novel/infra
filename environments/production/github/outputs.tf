# What the scripts around each plan and apply need, and no value: the Apps they read and write as,
# the repositories and environments whose objects they assert or prune, and the Secret Manager
# version each governance environment receives.
output "organizations" {
  description = "Per organization: the Plan App and the Deploy App with their keys, every repository, every managed environment, each governance secret's pinned version, and the secrets each repository's governance environment holds."
  value = {
    for owner, organization in var.organizations : owner => {
      project = var.management_project_id
      apps = {
        for role, app in var.apps[owner] : role => {
          id              = app.id
          installation_id = app.installation_id
          key             = { secret = "production-github-${role}-key-${owner}", version = app.key_version }
        }
      }
      repositories = sort(keys(local.owned[owner]))
      environments = { a-novel = module.a_novel.environments, a-novel-kit = module.a_novel_kit.environments }[owner]
      secrets = {
        for name, version in organization.governance_secrets : name => {
          secret  = "production-github-governance-${owner}-${lower(replace(name, "_", "-"))}"
          version = version
        }
      }
      governance = { a-novel = module.a_novel.governance_secrets, a-novel-kit = module.a_novel_kit.governance_secrets }[owner]
    }
  }
}
