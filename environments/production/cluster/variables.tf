variable "addon_images" {
  description = "Each add-on image's upstream reference, pinned by digest. It pulls through foundation's Artifact Registry cache of its registry."
  type        = map(string)

  validation {
    condition     = alltrue([for reference in values(var.addon_images) : can(regex("^(quay|ghcr)\\.io/[a-z0-9._/-]+:[^@]+@sha256:[a-f0-9]{64}$", reference))])
    error_message = "Every add-on image must come from quay.io or ghcr.io, pinned by digest."
  }
}

variable "backup_server_name" {
  description = "The name each database archives under in its Barman bucket, unique to its lineage."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,62}$", var.backup_server_name))
    error_message = "The backup server name must be a lowercase DNS label."
  }
}

variable "adopted_databases" {
  description = "The databases whose Cluster exists but which state lost, imported on the next apply. A create whose wait fails on a request deadline records nothing."
  type        = set(string)
  default     = []
}

variable "custom_resources" {
  description = "Whether to manage the resources whose kinds the add-ons define, and the Bitwarden SDK server, which mounts one's certificate. A fresh cluster lacks those kinds until the add-ons install, so a rebuild turns this off before the cluster is replaced and on once they run."
  type        = bool
}

variable "databases" {
  description = "Each service's database: each instance's CPU and memory, its volume, its connection ceiling and its extensions."
  type = map(object({
    cpu             = string
    memory          = string
    storage         = string
    max_connections = number
    extensions      = list(string)
  }))

  validation {
    condition     = alltrue([for service in keys(var.databases) : contains(var.namespaces, service)])
    error_message = "Each database belongs to a service's namespace."
  }
}

variable "namespaces" {
  description = "One namespace per service, holding its workloads, database and secrets."
  type        = set(string)

  validation {
    condition     = alltrue([for name in var.namespaces : can(regex("^[a-z][a-z0-9-]{0,62}$", name))])
    error_message = "Each namespace must be a lowercase DNS label."
  }
}

variable "secrets" {
  description = "Each service's secrets on the cluster: the variable its workloads read, and the name of its Secret Manager secret, production-<service>-<name>. Each version is the one the service's root pins."
  type        = map(map(string))

  validation {
    condition     = alltrue(flatten([for service, env in var.secrets : [for variable, name in env : can(regex("^[A-Z][A-Z0-9_]*$", variable)) && can(regex("^[a-z][a-z0-9-]*$", name))]]))
    error_message = "Name each variable in upper snake case, and each secret by its lowercase suffix."
  }
}
