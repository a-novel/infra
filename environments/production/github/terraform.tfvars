management_project_id = "a-novel-management-prod"

# anovelbot-plan, anovelbot-deploy, anovelkitbot-plan and anovelkitbot-deploy (a-novel/.github#535).
apps = {
  a-novel = {
    plan   = { id = 5544060, installation_id = 176950621, key_version = 1 }
    deploy = { id = 5544096, installation_id = 176950527, key_version = 1 }
  }
  a-novel-kit = {
    plan   = { id = 5544143, installation_id = 176950809, key_version = 1 }
    deploy = { id = 5544157, installation_id = 176950738, key_version = 1 }
  }
}

organizations = {
  a-novel = {
    bots           = { agent = 3549319, dependencies = 1717331, release = 5307879 }
    scoped_secrets = ["CODECOV_TOKEN", "TOKEN_EXPIRY_ADMIN"]
    # Each value is a version of production-github-governance-<org>-<name>; a deploy copies it.
    governance_secrets = { AGENT_BOT_PRIVATE_KEY = 2, BWS_READ_TOKEN = 1, DEPENDENCY_BOT_PRIVATE_KEY = 1 }
  }
  a-novel-kit = {
    bots               = { agent = 3549379, dependencies = 1734926, release = 5307968 }
    scoped_secrets     = ["CODECOV_TOKEN", "TOKEN_EXPIRY_ADMIN"]
    governance_secrets = { AGENT_BOT_PRIVATE_KEY = 1, BWS_READ_TOKEN = 1, DEPENDENCY_BOT_PRIVATE_KEY = 1 }
  }
}

tiers = {
  developers  = "push"
  maintainers = "maintain"
  owners      = "admin"
}

repositories = {
  "a-novel-kit/.github" = {
    class       = "meta"
    description = "Shared documentation and best practices."
    topics      = ["agora-storyverse", "code-of-conduct", "community-health", "contributing-guidelines", "documentation", "engineering-standards", "github-profile"]
  }
  "a-novel-kit/golib" = {
    class       = "library"
    description = "Shared Go libraries."
    topics      = ["agora-storyverse", "go", "go-library", "golang", "grpc", "observability", "opentelemetry", "postgresql", "shared-library", "smtp"]
  }
  "a-novel-kit/jwt" = {
    class       = "library"
    description = "A modular JWT library for Go, based on IANA specifications."
    topics      = ["agora-storyverse", "authentication", "cryptography", "go", "go-library", "golang", "jwa", "jwe", "jwk", "jws", "jwt", "security"]
  }
  "a-novel-kit/nodelib" = {
    class       = "library"
    description = "Shared Node.js libraries."
    topics      = ["agora-storyverse", "developer-tools", "eslint-config", "monorepo", "nodejs", "prettier-config", "shared-library", "typescript"]
  }
  "a-novel-kit/stack" = {
    class        = "library"
    description  = "Development tools backing a-novel and a-novel-kit. Home of the a-novel CLI and AI skills."
    homepage_url = "https://a-novel-kit.github.io/stack/"
    topics       = ["agent-skills", "agora-storyverse", "ai-agents", "claude-code", "cli", "developer-tools", "go", "golang", "monorepo"]
    overrides    = { pages = true }
  }
  "a-novel-kit/ui-assets" = {
    class = "library"
  }
  "a-novel-kit/uikit" = {
    class        = "library"
    description  = "Design system and brand assets."
    homepage_url = "https://a-novel-kit.github.io/uikit/"
    overrides    = { pages = true }
  }
  "a-novel-kit/workflows" = {
    class       = "workflows"
    description = "Shared github actions workflows."
    topics      = ["agora-storyverse", "automation", "ci-cd", "composite-actions", "continuous-integration", "devops", "github-actions", "reusable-workflows"]
  }
  "a-novel/.github" = {
    class       = "meta"
    description = "Shared documentation and best practices."
    topics      = ["agora-storyverse", "code-of-conduct", "community-health", "contributing-guidelines", "documentation", "engineering-standards", "github-profile"]
  }
  "a-novel/infra" = {
    class        = "infra"
    description  = "OpenTofu infrastructure and GitOps delivery on Google Cloud."
    homepage_url = "https://www.agorastoryverse.com"
  }
  "a-novel/platform-account" = {
    class        = "platform"
    description  = "The Agora account platform: sign-in, email links and account settings."
    homepage_url = "https://a-novel.github.io/platform-account/"
  }
  "a-novel/platform-studio" = {
    class        = "platform"
    description  = "The Studio creative platform."
    homepage_url = "https://a-novel.github.io/platform-studio/"
  }
  "a-novel/platform-template" = {
    class       = "platform"
    description = "A template repository for quickstarting client platforms."
    overrides   = { is_template = true }
  }
  "a-novel/service-authentication" = {
    class        = "service"
    description  = "Credentials manager and auth tokens public provider."
    homepage_url = "https://a-novel.github.io/service-authentication/"
    topics       = ["agora-storyverse", "authentication", "authorization", "go", "golang", "identity", "jwt", "microservice", "postgresql", "rest-api", "user-management"]
  }
  "a-novel/service-genai" = {
    class        = "service"
    description  = "Durable execution for AI provider calls: crash-safe, idempotent and pollable."
    homepage_url = "https://a-novel.github.io/service-genai/"
    topics       = ["agora-storyverse", "cost-tracking", "generative-ai", "go", "golang", "grpc", "llm", "llmops", "microservice", "openai", "postgresql"]
  }
  "a-novel/service-json-keys" = {
    class        = "service"
    description  = "Key encryption manager, based on IANA Json Web Algorithms. Provides JWK / JWE / JWS capabilities."
    homepage_url = "https://a-novel.github.io/service-json-keys/"
    topics       = ["agora-storyverse", "cryptography", "go", "golang", "grpc", "jwe", "jwk", "jws", "jwt", "key-management", "microservice", "postgresql", "rest-api"]
  }
  "a-novel/service-narrative-engine" = {
    class        = "service"
    description  = "The Narrative Engine powering the Studio application."
    homepage_url = "https://a-novel.github.io/service-narrative-engine/"
    topics       = ["agora-storyverse", "creative-writing", "generative-ai", "go", "golang", "llm", "microservice", "narrative-engine", "postgresql", "rest-api", "storytelling"]
  }
  "a-novel/service-template" = {
    class        = "service"
    description  = "A template repository for quickstarting backend services."
    homepage_url = "https://a-novel.github.io/service-template/"
    topics       = ["agora-storyverse", "boilerplate", "clean-architecture", "go", "golang", "grpc", "microservice", "postgresql", "rest-api", "scaffolding", "template"]
    overrides    = { is_template = true }
  }
}

labels = {
  "documentation"                 = { color = "0075ca", description = "Improvements or additions to documentation" }
  "duplicate"                     = { color = "cfd3d7", description = "This issue or pull request already exists" }
  "good first issue"              = { color = "7057ff", description = "Good for newcomers" }
  "help wanted"                   = { color = "008672", description = "Extra attention is needed" }
  "invalid"                       = { color = "e4e669", description = "This doesn't seem right" }
  "question"                      = { color = "d876e3", description = "Further information is requested" }
  "wontfix"                       = { color = "ffffff", description = "This will not be worked on" }
  "dependencies"                  = { color = "ededed", description = "" }
  "meta"                          = { color = "bfd4f2", description = "No-PR work (manual ops / config); also marks Meta Epics" }
  "append-only-override"          = { color = "fbca04", description = "Allows a reviewed change to files protected by an append-only CI check" }
  "allow-dependency-change"       = { color = "fbca04", description = "A reviewer acknowledges the dependency manifests this pull request changes" }
  "allow-screenshot-change"       = { color = "c5def5", description = "Approve visual changes for the reviewed PR head; functional tests remain required" }
  "allow-incomplete-translations" = { color = "fbca04", description = "Accepts translations this PR leaves empty; they render the English text" }
  "allow-translation-drift"       = { color = "fbca04", description = "Accepts English changes whose translations this PR leaves unchanged" }
  "buf skip breaking"             = { color = "fbca04", description = "A reviewer accepts the breaking proto change this pull request makes" }
  "with-feature-env"              = { color = "0e8a16", description = "Tags this pull request's images for its current head; a push removes it" }
  "automation:paused"             = { color = "d93f0b", description = "Pauses this Epic's [Agent] automation (best-effort; org kill-switch is the hard halt)" }
  "escalation"                    = { color = "b60205", description = "Automated governance escalation (escalate action)." }
}
