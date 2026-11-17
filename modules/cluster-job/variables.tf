variable "name" {
  description = "The Job's or CronJob's name. A Job's template never changes once created, so a Job that must run again takes a new name."
  type        = string
}

variable "namespace" {
  description = "The namespace the job runs in."
  type        = string
}

variable "schedule" {
  description = "A cron schedule, in UTC. When set, a CronJob starts each run on it. Otherwise one Job runs, and the apply waits for it to complete."
  type        = string
  default     = null
}

variable "suspend" {
  description = "Whether the CronJob starts no run of its own, as a template that operators copy."
  type        = bool
  default     = null
}

variable "labels" {
  description = "The pod labels, which network policies select."
  type        = map(string)
  default     = null
}

variable "service_account" {
  description = "The Kubernetes service account the pods run as, which the service they call may admit. Null runs them as the namespace's default."
  type        = string
  default     = null
}

variable "user" {
  description = "The unprivileged user and group the pods run as."
  type        = number
  default     = 65532
}

variable "container_name" {
  description = "The container's name."
  type        = string
}

variable "image" {
  description = "The image, pinned by digest, as admission requires."
  type        = string

  validation {
    condition     = can(regex("@sha256:[a-f0-9]{64}$", var.image))
    error_message = "Pin the image by digest."
  }
}

variable "command" {
  description = "The container's entrypoint. Null keeps the image's."
  type        = list(string)
  default     = null
}

variable "args" {
  description = "The entrypoint's arguments. Null keeps the image's."
  type        = list(string)
  default     = null
}

variable "env" {
  description = "Plain environment variables."
  type        = map(string)
  default     = {}
}

variable "secret_env" {
  description = "Environment variables read from the namespace's Secrets, after the plain ones and in this order: each names a Secret and its key."
  type = list(object({
    name   = string
    secret = string
    key    = string
  }))
  default = []
}

variable "ca_secret" {
  description = "The namespace's Secret whose `ca.crt` the container reads in /etc/database-ca: its database's CA."
  type        = string
  default     = null
}

variable "service_token" {
  description = "The audience of the service token the kubelet projects into /var/run/secrets/tokens/<audience>, for the service API the job calls."
  type        = string
  default     = null
}

variable "service_ca" {
  description = "The namespace's ConfigMap whose `ca.crt` the container reads in /etc/service-ca: the services CA, which trust-manager copies there."
  type        = string
  default     = null
}

variable "tmp_size" {
  description = "The size of a memory-backed /tmp, for a program that writes files beside its read-only root filesystem. Null mounts none."
  type        = string
  default     = null
}

variable "resources" {
  description = "Each pod's CPU request and memory, which also bounds it."
  type = object({
    cpu    = string
    memory = string
  })
}

variable "active_deadline_seconds" {
  description = "How long a run may take before Kubernetes ends it. A Job's ends before its timeout, so a run never outlives the apply's wait."
  type        = number
}

variable "timeout" {
  description = "How long the apply waits for the Job to complete, as a duration such as 6m. A CronJob takes none."
  type        = string
  default     = null
}
