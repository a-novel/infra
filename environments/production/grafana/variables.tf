variable "management_project_id" {
  description = "Management project ID, which holds the Grafana token secrets."
  type        = string
}

variable "url" {
  description = "The Grafana Cloud stack this root configures, such as https://<stack>.grafana.net."
  type        = string

  validation {
    condition     = can(regex("^https://[a-z0-9-]+\\.grafana\\.net$", var.url))
    error_message = "Use the stack's Grafana Cloud URL, without a trailing slash."
  }
}

variable "token_versions" {
  description = "Numeric versions of the Grafana token secrets, by CI identity."
  type = object({
    plan   = number
    deploy = number
  })
}

variable "writer" {
  description = "Whether the run applies. The tofu action sets it, and only a deploy reads the token that writes."
  type        = bool
  default     = false
}

variable "contact_point" {
  description = "Name of the Discord contact point, which core creates by hand in the stack."
  type        = string
}

variable "alerts" {
  description = "Each service's alert thresholds, by repository: the failing share of its requests and job runs, the p95 duration of its requests in seconds, and the spans whose duration says nothing of slowness."
  type = map(object({
    failure_rate    = number
    p95_seconds     = number
    latency_ignores = optional(list(string), [])
  }))

  validation {
    condition     = alltrue([for alert in values(var.alerts) : alert.failure_rate > 0 && alert.failure_rate < 1])
    error_message = "A failing share lies between 0 and 1."
  }

  # Alloy's span-metric histogram tops out at 30 seconds (the cluster root's alloy.tf), so a p95
  # above it reads as 30.
  validation {
    condition     = alltrue([for alert in values(var.alerts) : alert.p95_seconds > 0 && alert.p95_seconds < 30])
    error_message = "A p95 threshold lies below 30 seconds, the span-metric histogram's largest bucket, or its alert never fires."
  }
}

variable "thresholds" {
  description = "The platform alerts' thresholds: the used share of a volume, a node's CPU and memory, a replica's replay lag in seconds, and the share of a Grafana Cloud allowance."
  type = object({
    volume_warning  = number
    volume_critical = number
    node_cpu        = number
    node_memory     = number
    replica_lag     = number
    usage           = number
  })
}
