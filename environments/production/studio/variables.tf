variable "images" {
  description = "Platform images as ghcr.io/a-novel/platform-studio:<tag>@<digest>, pinned by each release."
  type        = map(string)

  validation {
    condition = toset(keys(var.images)) == toset(["web"]) && alltrue([
      for ref in values(var.images) : can(regex("^ghcr\\.io/a-novel/platform-studio:v[0-9]+\\.[0-9]+\\.[0-9]+@sha256:[a-f0-9]{64}$", ref))
    ])
    error_message = "Pin the web image by release tag and digest."
  }
}

variable "alert_email" {
  description = "Operations inbox for this platform's alerts."
  type        = string
  sensitive   = true
}
