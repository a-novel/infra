# GitHub gave a-novel/service-profile its default labels when it created the repository, so the
# root's labels of the same names already exist there (a-novel/infra#1502). Once applied, this block
# goes.
import {
  for_each = toset(["documentation", "duplicate", "good first issue", "help wanted", "invalid", "question", "wontfix"])
  to       = module.a_novel.github_issue_label.this["service-profile:${each.key}"]
  id       = "service-profile:${each.key}"
}
