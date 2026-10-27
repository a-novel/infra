management_project_id = "a-novel-management-prod"

# The US organization, until a-novel/infra#1107 moves to the EU one.
organization = "a-novel"
base_url     = "https://sentry.io/api/"
team         = "a-novel-devs"

projects = [
  "service-authentication",
  "service-genai",
  "service-json-keys",
]

token_versions = {
  plan   = 1
  deploy = 1
}
