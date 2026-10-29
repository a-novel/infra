variable "name" {
  description = "The workload's name, which its service account, Deployment, Service and pods share."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,40}$", var.name))
    error_message = "The name must be a short lowercase DNS label."
  }
}

variable "namespace" {
  description = "The service's namespace."
  type        = string
}

variable "image" {
  description = "The image, in our Artifact Registry and pinned by digest, as admission requires."
  type        = string

  validation {
    condition     = can(regex("@sha256:[a-f0-9]{64}$", var.image))
    error_message = "Pin the image by digest."
  }
}

variable "port" {
  description = "The port the workload serves on."
  type        = number
}

variable "http_health_path" {
  description = "When set, the workload serves HTTP, and its probes GET this path. Otherwise it serves gRPC, and its probes call the standard health service."
  type        = string
  default     = null
}

variable "env" {
  description = "Plain environment variables."
  type        = map(string)
  default     = {}
}

variable "secret_env" {
  description = "Environment variables read from the namespace's Secrets: each names a Secret and its key."
  type = map(object({
    secret = string
    key    = string
  }))
  default = {}
}

variable "service_tokens" {
  description = "The service tokens the workload sends to the services it calls: each callee's audience, to the variable that names the file the kubelet projects its token into."
  type        = map(string)
  default     = {}
}

variable "ca_secret" {
  description = "The namespace's Secret whose `ca.crt` the workload trusts beside the system roots: its database's CA."
  type        = string
}

variable "resources" {
  description = "Each pod's CPU request and memory, which also bounds it."
  type = object({
    cpu    = string
    memory = string
  })
}

variable "replicas" {
  description = "The pods to run: an autoscaler moves between min and max on CPU; equal bounds run a fixed count."
  type = object({
    min = number
    max = number
  })

  validation {
    condition     = var.replicas.min >= 1 && var.replicas.max >= var.replicas.min
    error_message = "Run at least one pod, and no fewer at most than at least."
  }
}

variable "labels" {
  description = "Extra pod labels, which network policies select, such as a database client's."
  type        = map(string)
  default     = {}
}
