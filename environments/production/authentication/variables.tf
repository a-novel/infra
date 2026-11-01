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
