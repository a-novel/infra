# The cluster root reads these pins from this root's terraform.tfvars.
# tflint-ignore: terraform_unused_declarations
variable "images" {
  description = "Service images as ghcr.io/a-novel/<path>:<tag>@<digest>, pinned by each release."
  type        = map(string)

  validation {
    condition = toset(keys(var.images)) == toset(["database", "grpc", "migrations", "rotatekeys"]) && alltrue([
      for ref in values(var.images) : can(regex("^ghcr\\.io/a-novel/service-json-keys/[^:@]+:v[0-9]+\\.[0-9]+\\.[0-9]+@sha256:[a-f0-9]{64}$", ref))
    ])
    error_message = "Pin the database, grpc, migrations and rotatekeys images by release tag and digest."
  }
}

# The cluster root reads these versions from this root's terraform.tfvars.
# tflint-ignore: terraform_unused_declarations
variable "secret_versions" {
  description = "Numeric secret versions the workloads read, by secret name suffix."
  type        = map(number)

  validation {
    condition     = toset(keys(var.secret_versions)) == toset(["app-master-key"])
    error_message = "Pin exactly the app-master-key version."
  }
}
