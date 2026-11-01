# GitHub gave a-novel/platform-account its default labels when it created the repository, so the
# root's labels of the same names already exist there (a-novel/infra#1379). Once applied, this block
# goes.
import {
  for_each = toset(["dependencies", "documentation", "duplicate", "help wanted", "invalid", "question", "wontfix"])
  to       = module.a_novel.github_issue_label.this["platform-account:${each.key}"]
  id       = "platform-account:${each.key}"
}
