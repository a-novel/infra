variable "management_project_id" {
  description = "Management project ID, which holds the Grafana token secrets."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.management_project_id))
    error_message = "The management project ID must be a valid 6-30 character Google Cloud project ID."
  }
}

variable "url" {
  description = "The Grafana Cloud stack this root configures, such as https://<stack>.grafana.net."
  type        = string

  validation {
    condition     = can(regex("^https://[a-z0-9-]+\\.grafana\\.net$", var.url))
    error_message = "Use the stack's Grafana Cloud URL, without a trailing slash."
  }
}

variable "stack_id" {
  description = "The stack's numeric ID, which the v2 dashboard API addresses. Grafana's /api/frontend/settings shows it as the namespace stacks-<ID>."
  type        = number
}

variable "token_versions" {
  description = "Numeric versions of the Grafana token secrets, by CI identity: the stack's tokens, then the Grafana Cloud tokens of Frontend Observability."
  type = object({
    plan         = number
    deploy       = number
    cloud_plan   = number
    cloud_deploy = number
  })
}

variable "faro_apps" {
  description = "The origin of each platform that reports browser telemetry to Faro, by repository. Foundation's platform_hosts names the same hosts."
  type        = map(string)

  validation {
    condition     = alltrue([for origin in values(var.faro_apps) : can(regex("^https://[a-z0-9.-]+$", origin))])
    error_message = "An origin is https://<host>, without a path or a trailing slash."
  }
}

variable "writer" {
  description = "Whether the run applies. The tofu action sets it, and only a deploy reads the token that writes."
  type        = bool
  default     = false
}

variable "contact_point" {
  description = "Name of the chat's contact point, which core creates by hand in the stack."
  type        = string
}

variable "alerts" {
  description = "Each service's alert thresholds, by repository: the failing share of its requests and job runs, the p95 duration of its requests in seconds, and the spans whose duration says nothing of slowness, as regular expressions."
  type = map(object({
    failure_rate    = number
    p95_seconds     = number
    latency_ignores = optional(list(string), [])
  }))

  validation {
    condition     = alltrue([for alert in values(var.alerts) : alert.failure_rate > 0 && alert.failure_rate < 1])
    error_message = "A failing share lies between 0 and 1."
  }

  validation {
    condition     = alltrue([for alert in values(var.alerts) : alert.p95_seconds > 0])
    error_message = "A p95 threshold is a positive duration."
  }
}

variable "thresholds" {
  description = "The platform and capacity alerts' thresholds: the used share of a volume, a node's CPU and memory, a container's CPU request and memory limit, and a database's connections; a replica's replay lag in seconds; and the share of a Grafana Cloud allowance."
  type = object({
    volume_warning  = number
    volume_critical = number
    node_cpu        = number
    node_memory     = number
    replica_lag     = number
    usage           = number
    # The used share of a container's CPU request and memory limit, and of a database's connections.
    container_cpu        = number
    container_memory     = number
    database_connections = number
    service_budget       = number
  })
}
