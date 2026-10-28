variable "namespaces" {
  description = "One namespace per service, holding its workloads, database and secrets."
  type        = set(string)

  validation {
    condition     = alltrue([for name in var.namespaces : can(regex("^[a-z][a-z0-9-]{0,62}$", name))])
    error_message = "Each namespace must be a lowercase DNS label."
  }
}
