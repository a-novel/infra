config {
  call_module_type = "all"
  force            = false
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "google" {
  enabled = true
  # renovate: datasource=github-releases depName=terraform-linters/tflint-ruleset-google
  version = "0.39.0"
  source  = "github.com/terraform-linters/tflint-ruleset-google"
}
