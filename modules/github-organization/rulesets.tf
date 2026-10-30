# Each ruleset's structure. The required checks come from discovery, and the bypass actors from the
# organization's bots, the repository's class and its workflows.
locals {
  ruleset_templates = {
    master = {
      target = "branch", include = ["~DEFAULT_BRANCH"], exclude = []
      bypass = ["admins", "release"]
      rules  = { creation = false, update = false, deletion = true, non_fast_forward = true, required_signatures = true }
      checks = true, merge_queue = true, pull_request = false, commit_message_pattern = false
    }
    # Every commit on every branch, so a pull request's history is clean before it merges.
    commit-messages = {
      target = "branch", include = ["~ALL"], exclude = ["refs/heads/gh-readonly-queue/**"]
      bypass = ["dependabot"]
      rules  = { creation = false, update = false, deletion = false, non_fast_forward = false, required_signatures = false }
      checks = false, merge_queue = false, pull_request = false, commit_message_pattern = true
    }
    # The v<N> branches below the major the default branch develops.
    retired-lines = {
      target = "branch", include = [], exclude = []
      bypass = ["admins"]
      rules  = { creation = true, update = true, deletion = true, non_fast_forward = true, required_signatures = false }
      checks = false, merge_queue = false, pull_request = false, commit_message_pattern = false
    }
    require-approval = {
      target = "branch", include = ["~DEFAULT_BRANCH"], exclude = []
      bypass = ["admins", "dependencies", "release"]
      rules  = { creation = false, update = false, deletion = false, non_fast_forward = false, required_signatures = false }
      checks = false, merge_queue = false, pull_request = true, commit_message_pattern = false
    }
    # Only the release App and admins create, move or delete a tag.
    tags = {
      target = "tag", include = ["~ALL"], exclude = []
      bypass = ["admins", "release"]
      rules  = { creation = true, update = true, deletion = true, non_fast_forward = true, required_signatures = false }
      checks = false, merge_queue = false, pull_request = false, commit_message_pattern = false
    }
    # release/vX.Y lines are governed like the default branch.
    release-lines = {
      target = "branch", include = ["refs/heads/release/**"], exclude = []
      bypass = ["admins", "release"]
      rules  = { creation = true, update = false, deletion = true, non_fast_forward = true, required_signatures = true }
      checks = true, merge_queue = false, pull_request = true, commit_message_pattern = false
    }
  }

  rulesets = merge([
    for name in local.ready : {
      for ruleset, on in {
        master           = true
        commit-messages  = true
        retired-lines    = local.discovered[name].major > 0
        require-approval = true
        tags             = var.repositories[name].tags_ruleset
        release-lines    = var.repositories[name].tags_ruleset
      } : "${name}:${ruleset}" => { repository = name, ruleset = ruleset } if on
    }
  ]...)

  # Bots write directly where they bypass in mode always, and reach other refs through pull requests.
  bot_mode = { for ruleset in keys(local.ruleset_templates) : ruleset => contains(["master", "tags", "release-lines"], ruleset) ? "always" : "exempt" }

  bypass_actors = {
    for key, ruleset in local.rulesets : key => flatten([
      for entry in local.ruleset_templates[ruleset.ruleset].bypass : (
        entry == "admins" ? [
          { actor_id = null, actor_type = "OrganizationAdmin", bypass_mode = "always" },
          { actor_id = 5, actor_type = "RepositoryRole", bypass_mode = "always" },
        ] :
        entry == "dependabot" ? [{ actor_id = 29110, actor_type = "Integration", bypass_mode = local.bot_mode[ruleset.ruleset] }] :
        [{ actor_id = var.bots[entry], actor_type = "Integration", bypass_mode = local.bot_mode[ruleset.ruleset] }]
      )
      # GitHub accepts Dependabot only where it runs, and the release App acts only where releases
      # do. A class whose merges deploy production keeps the admins alone.
      if(
        (entry == "admins" || !var.repositories[ruleset.repository].admins_only) &&
        (entry != "dependabot" || var.repositories[ruleset.repository].dependabot_security_updates) &&
        (entry != "release" || contains(local.discovered[ruleset.repository].environments, "release"))
      )
    ])
  }
}

resource "github_repository_ruleset" "this" {
  for_each = local.rulesets

  repository  = github_repository.this[each.value.repository].name
  name        = each.value.ruleset
  target      = local.ruleset_templates[each.value.ruleset].target
  enforcement = "active"

  dynamic "bypass_actors" {
    for_each = local.bypass_actors[each.key]

    content {
      actor_id    = bypass_actors.value.actor_id
      actor_type  = bypass_actors.value.actor_type
      bypass_mode = bypass_actors.value.bypass_mode
    }
  }

  conditions {
    ref_name {
      include = each.value.ruleset == "retired-lines" ? [
        for major in range(local.discovered[each.value.repository].major) : "refs/heads/v${major}"
      ] : local.ruleset_templates[each.value.ruleset].include
      exclude = local.ruleset_templates[each.value.ruleset].exclude
    }
  }

  rules {
    creation            = local.ruleset_templates[each.value.ruleset].rules.creation
    update              = local.ruleset_templates[each.value.ruleset].rules.update
    deletion            = local.ruleset_templates[each.value.ruleset].rules.deletion
    non_fast_forward    = local.ruleset_templates[each.value.ruleset].rules.non_fast_forward
    required_signatures = local.ruleset_templates[each.value.ruleset].rules.required_signatures

    dynamic "required_status_checks" {
      for_each = local.ruleset_templates[each.value.ruleset].checks ? [local.discovered[each.value.repository].checks] : []

      content {
        strict_required_status_checks_policy = true
        do_not_enforce_on_create             = false

        dynamic "required_check" {
          for_each = required_status_checks.value

          content {
            context        = required_check.key
            integration_id = required_check.value
          }
        }
      }
    }

    # A merge group runs the required checks again, 3x the slowest merge-group run as its timeout.
    dynamic "merge_queue" {
      for_each = local.ruleset_templates[each.value.ruleset].merge_queue ? [1] : []

      content {
        grouping_strategy                 = "ALLGREEN"
        merge_method                      = "SQUASH"
        check_response_timeout_minutes    = 15
        max_entries_to_build              = 5
        max_entries_to_merge              = 5
        min_entries_to_merge              = 1
        min_entries_to_merge_wait_minutes = 5
      }
    }

    dynamic "pull_request" {
      for_each = local.ruleset_templates[each.value.ruleset].pull_request ? [1] : []

      content {
        allowed_merge_methods             = ["squash"]
        required_approving_review_count   = 1
        dismiss_stale_reviews_on_push     = true
        require_last_push_approval        = true
        required_review_thread_resolution = true
        require_code_owner_review         = false
      }
    }

    dynamic "commit_message_pattern" {
      for_each = local.ruleset_templates[each.value.ruleset].commit_message_pattern ? [1] : []

      content {
        name     = "Conventional Commits subject"
        operator = "regex"
        pattern  = "^(build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test)(\\([^)]+\\))?!?: \\S"
        negate   = false
      }
    }
  }
}
