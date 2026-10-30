# What the scripts that follow each apply need, and no value: the Deploy App they write as, the
# repositories whose settings they assert, and the Secret Manager version each governance
# environment receives.
output "organizations" {
  description = "Per organization: the Deploy App and its key, every repository, each governance secret's pinned version, and the secrets each repository's governance environment holds."
  value = {
    for owner, organization in var.organizations : owner => {
      project = var.management_project_id
      app = {
        id              = var.apps[owner].deploy.id
        installation_id = var.apps[owner].deploy.installation_id
        key             = { secret = "production-github-deploy-key-${owner}", version = var.apps[owner].deploy.key_version }
      }
      repositories = sort(keys(local.owned[owner]))
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
