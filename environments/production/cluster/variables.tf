variable "addon_images" {
  description = "Each add-on image's upstream reference, pinned by digest. It pulls through foundation's Artifact Registry cache of its registry."
  type        = map(string)

  validation {
    condition     = alltrue([for reference in values(var.addon_images) : can(regex("^(docker\\.io|ghcr\\.io|quay\\.io|registry\\.k8s\\.io)/[a-z0-9._/-]+:[^@]+@sha256:[a-f0-9]{64}$", reference))])
    error_message = "Every add-on image must come from Docker Hub, ghcr.io, quay.io or registry.k8s.io, pinned by digest."
  }
}

variable "addon_secret_versions" {
  description = "Each add-on's secrets on the cluster, by namespace, at the version this root pins: each name is the suffix of production-<namespace>-<name>."
  type        = map(map(number))
  default     = {}
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
  description = "Whether to manage the resources whose kinds the add-ons define. A fresh cluster lacks those kinds until the add-ons install, so a rebuild turns this off before the cluster is replaced and on once they run."
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

variable "grafana_cloud" {
  description = "The Grafana Cloud stack Alloy sends to: its instance ID, which names the sender, and its OTLP gateway's host."
  type = object({
    instance_id = string
    otlp_host   = string
  })
}

variable "namespaces" {
  description = "One namespace per service, holding its workloads, database and secrets."
  type        = set(string)

  validation {
    condition     = alltrue([for name in var.namespaces : can(regex("^[a-z][a-z0-9-]{0,62}$", name))])
    error_message = "Each namespace must be a lowercase DNS label."
  }
}

variable "service_budgets" {
  description = "Each service's ceiling on the cluster, as a ResourceQuota on its namespace: the CPU and memory its pods may request in all, and the pods that may run. Its autoscalers grow inside it, and raising it is a deliberate change."
  type = map(object({
    cpu    = string
    memory = string
    pods   = number
  }))

  validation {
    condition     = toset(keys(var.service_budgets)) == var.namespaces
    error_message = "Every service namespace needs a budget, and every budget a namespace."
  }
}

variable "secrets" {
  description = "Each namespace's secrets on the cluster: the variable its workloads read, and the name of its Secret Manager secret, production-<namespace>-<name>. A service's version is the one its root pins, and an add-on's is in addon_secret_versions."
  type        = map(map(string))

  validation {
    condition     = alltrue(flatten([for service, env in var.secrets : [for variable, name in env : can(regex("^[A-Z][A-Z0-9_]*$", variable)) && can(regex("^[a-z][a-z0-9-]*$", name))]]))
    error_message = "Name each variable in upper snake case, and each secret by its lowercase suffix."
  }
}

variable "downtime" {
  description = "The planned downtime as JSON, from the DOWNTIME repository variable: components, start and end. Empty without one."
  type        = string
  default     = ""

  validation {
    condition     = var.downtime == "" || can(tolist(jsondecode(var.downtime).components)) && can(jsondecode(var.downtime).start)
    error_message = "The planned downtime must be JSON with components, start and end."
  }
}
