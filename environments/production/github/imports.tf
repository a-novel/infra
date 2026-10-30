# The GitHub root adopts what `a-novel repo update` built (a-novel/.github#534). Once applied, these
# blocks and the adopt variable go.
locals {
  adopted = var.adopt ? local.repositories : {}

  adopted_tiers = { for pair in setproduct(keys(var.adopt ? var.apps : {}), keys(var.tiers)) : "${pair[0]}/${pair[1]}" => { owner = pair[0], team = pair[1] } }
  adopted_areas = {
    for area in distinct([for repository in values(local.adopted) : { owner = repository.owner, class = repository.class }]) :
    "${area.owner}/${area.class}" => area
  }
  adopted_labels = {
    for pair in setproduct(keys(local.adopted), keys(var.labels)) : "${pair[0]}:${pair[1]}" => {
      owner = local.adopted[pair[0]].owner
      name  = local.adopted[pair[0]].name
      label = pair[1]
    }
  }
}

import {
  for_each = local.adopted
  to       = module.organization[each.value.owner].github_repository.this[each.value.name]
  id       = each.value.name
}

import {
  for_each = { for name, repository in local.adopted : name => repository if repository.pages }
  to       = module.organization[each.value.owner].github_repository_pages.this[each.value.name]
  id       = each.value.name
}

import {
  for_each = local.adopted
  to       = module.organization[each.value.owner].github_workflow_repository_permissions.this[each.value.name]
  id       = each.value.name
}

import {
  for_each = local.adopted
  to       = module.organization[each.value.owner].github_repository_vulnerability_alerts.this[each.value.name]
  id       = each.value.name
}

import {
  for_each = local.adopted
  to       = module.organization[each.value.owner].github_repository_dependabot_security_updates.this[each.value.name]
  id       = each.value.name
}

import {
  for_each = local.adopted
  to       = module.organization[each.value.owner].github_repository_collaborators.this[each.value.name]
  id       = each.value.name
}

import {
  for_each = local.adopted_tiers
  to       = module.organization[each.value.owner].github_team.tier[each.value.team]
  id       = each.value.team
}

import {
  for_each = { for pair in setproduct(values(local.adopted_areas), keys(var.tiers)) : "${pair[0].owner}/${pair[1]}-${pair[0].class}" => { owner = pair[0].owner, team = "${pair[1]}-${pair[0].class}" } }
  to       = module.organization[each.value.owner].github_team.area[each.value.team]
  id       = each.value.team
}

import {
  for_each = local.adopted_labels
  to       = module.organization[each.value.owner].github_issue_label.this["${each.value.name}:${each.value.label}"]
  id       = "${each.value.name}:${each.value.label}"
}
