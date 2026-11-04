# The cluster root reads these pins from this root's terraform.tfvars.
# tflint-ignore: terraform_unused_declarations
variable "images" {
  description = "Service images as ghcr.io/a-novel/<path>:<tag>@<digest>, pinned by each release."
  type        = map(string)

  validation {
    condition = toset(keys(var.images)) == toset(["database", "migrations", "rest"]) && alltrue([
      for ref in values(var.images) : can(regex("^ghcr\\.io/a-novel/service-profile/[^:@]+:v[0-9]+\\.[0-9]+\\.[0-9]+@sha256:[a-f0-9]{64}$", ref))
    ])
    error_message = "Pin the database, migrations and rest images by release tag and digest."
  }
}
