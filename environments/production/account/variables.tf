# Account runs only on the cluster. This root holds its release pin, which the cluster root reads
# from terraform.tfvars, so a release pins it as it pins every service's.
# tflint-ignore: terraform_unused_declarations
variable "images" {
  description = "Platform images as ghcr.io/a-novel/platform-account:<tag>@<digest>, pinned by each release."
  type        = map(string)

  validation {
    condition = toset(keys(var.images)) == toset(["web"]) && alltrue([
      for ref in values(var.images) : can(regex("^ghcr\\.io/a-novel/platform-account:v[0-9]+\\.[0-9]+\\.[0-9]+@sha256:[a-f0-9]{64}$", ref))
    ])
    error_message = "Pin the web image by release tag and digest."
  }
}
