output "governance_secrets" {
  description = "The privileged secrets each repository's workflows name, by repository: what its governance environment must hold."
  value = {
    for key, environment in local.environments : environment.repository => sort(setintersection(local.discovered[environment.repository].secrets, var.governance_secrets))
    if environment.environment == "governance"
  }
}

output "environments" {
  description = "The environments the module manages, as \"<repository>:<environment>\": prune reads the deployment patterns of these alone."
  value       = sort(keys(local.environments))
}
