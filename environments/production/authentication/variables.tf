# The cluster root reads these pins from this root's terraform.tfvars.
# tflint-ignore: terraform_unused_declarations
variable "images" {
  description = "Service images as ghcr.io/a-novel/<path>:<tag>@<digest>, pinned by each release."
  type        = map(string)

  validation {
    condition = toset(keys(var.images)) == toset(["database", "maintenance", "migrations", "rest"]) && alltrue([
      for ref in values(var.images) : can(regex("^ghcr\\.io/a-novel/service-authentication/[^:@]+:v[0-9]+\\.[0-9]+\\.[0-9]+@sha256:[a-f0-9]{64}$", ref))
    ])
    error_message = "Pin the database, maintenance, migrations and rest images by release tag and digest."
  }
}

# The cluster root reads the SMTP settings from this root's terraform.tfvars.
# tflint-ignore: terraform_unused_declarations
variable "smtp" {
  description = "Hosted SMTP relay settings. The relay admits the production NAT address without a password."
  type = object({
    host         = string
    sender_email = string
    sender_name  = string
  })
}

# The cluster root reads these versions from this root's terraform.tfvars.
# tflint-ignore: terraform_unused_declarations
variable "secret_versions" {
  description = "Numeric secret versions the workloads read, by secret name suffix."
  type        = map(number)

  validation {
    condition     = toset(keys(var.secret_versions)) == toset(["waitlist-secret"])
    error_message = "Pin exactly the waitlist-secret version."
  }
}

# The cluster root reads the invitation list's address from this root's terraform.tfvars.
# Authentication refuses to start on any other shape, so the plan refuses it first.
# tflint-ignore: terraform_unused_declarations
variable "waitlist_url" {
  description = "The invitation list's Apps Script web app (service-authentication's scripts/waitlist), which checks each request against the waitlist-secret."
  type        = string

  validation {
    condition     = can(regex("^https://script\\.google\\.com/macros/s/[A-Za-z0-9_-]+/exec$", var.waitlist_url))
    error_message = "Use the web app's https://script.google.com/macros/s/<deployment>/exec address, with no query."
  }
}
