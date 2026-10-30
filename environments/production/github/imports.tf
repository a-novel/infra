# The GitHub root adopts what `a-novel repo update` built (a-novel/.github#534). Once applied, these
# blocks and the adopt variable go.
locals {
  adopted = { for owner, repositories in local.owned : owner => var.adopt ? repositories : {} }

  # Each tier's area team for each class an organization has a repository of.
  adopted_areas = { for owner, repositories in local.adopted : owner => toset(flatten([
    for tier in keys(var.tiers) : [for repository in values(repositories) : "${tier}-${repository.class}"]
  ])) }

  # Each label's import ID, "<repository>:<label>", is also its address in the module.
  adopted_labels = { for owner, repositories in local.adopted : owner => toset([
    for pair in setproduct(keys(repositories), keys(var.labels)) : "${pair[0]}:${pair[1]}"
  ]) }
}

# a-novel
import {
  for_each = local.adopted["a-novel"]
  to       = module.a_novel.github_repository.this[each.key]
  id       = each.key
}

import {
  for_each = { for name, repository in local.adopted["a-novel"] : name => repository if repository.pages }
  to       = module.a_novel.github_repository_pages.this[each.key]
  id       = each.key
}

import {
  for_each = local.adopted["a-novel"]
  to       = module.a_novel.github_workflow_repository_permissions.this[each.key]
  id       = each.key
}

import {
  for_each = local.adopted["a-novel"]
  to       = module.a_novel.github_repository_vulnerability_alerts.this[each.key]
  id       = each.key
}

import {
  for_each = local.adopted["a-novel"]
  to       = module.a_novel.github_repository_dependabot_security_updates.this[each.key]
  id       = each.key
}

import {
  for_each = local.adopted["a-novel"]
  to       = module.a_novel.github_repository_collaborators.this[each.key]
  id       = each.key
}

import {
  for_each = length(local.adopted["a-novel"]) > 0 ? var.tiers : {}
  to       = module.a_novel.github_team.tier[each.key]
  id       = each.key
}

import {
  for_each = local.adopted_areas["a-novel"]
  to       = module.a_novel.github_team.area[each.key]
  id       = each.key
}

import {
  for_each = local.adopted_labels["a-novel"]
  to       = module.a_novel.github_issue_label.this[each.key]
  id       = each.key
}

# a-novel-kit
import {
  for_each = local.adopted["a-novel-kit"]
  to       = module.a_novel_kit.github_repository.this[each.key]
  id       = each.key
}

import {
  for_each = { for name, repository in local.adopted["a-novel-kit"] : name => repository if repository.pages }
  to       = module.a_novel_kit.github_repository_pages.this[each.key]
  id       = each.key
}

import {
  for_each = local.adopted["a-novel-kit"]
  to       = module.a_novel_kit.github_workflow_repository_permissions.this[each.key]
  id       = each.key
}

import {
  for_each = local.adopted["a-novel-kit"]
  to       = module.a_novel_kit.github_repository_vulnerability_alerts.this[each.key]
  id       = each.key
}

import {
  for_each = local.adopted["a-novel-kit"]
  to       = module.a_novel_kit.github_repository_dependabot_security_updates.this[each.key]
  id       = each.key
}

import {
  for_each = local.adopted["a-novel-kit"]
  to       = module.a_novel_kit.github_repository_collaborators.this[each.key]
  id       = each.key
}

import {
  for_each = length(local.adopted["a-novel-kit"]) > 0 ? var.tiers : {}
  to       = module.a_novel_kit.github_team.tier[each.key]
  id       = each.key
}

import {
  for_each = local.adopted_areas["a-novel-kit"]
  to       = module.a_novel_kit.github_team.area[each.key]
  id       = each.key
}

import {
  for_each = local.adopted_labels["a-novel-kit"]
  to       = module.a_novel_kit.github_issue_label.this[each.key]
  id       = each.key
}
