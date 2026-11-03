# GitHub gave a-novel/service-profile its default labels when it created the repository, and Renovate
# added `dependencies` with its first pull requests, so the root's labels of those names already
# existed there (a-novel/infra#1502). #1507 adopted the defaults; this adopts `dependencies`. Once
# applied, this block goes.
import {
  to = module.a_novel.github_issue_label.this["service-profile:dependencies"]
  id = "service-profile:dependencies"
}
