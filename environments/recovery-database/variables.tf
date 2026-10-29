variable "recovery" {
  description = "The drill, from recovery.yaml's drill input: its disposable project, the service whose database it restores, and the time to recover to, empty for the latest."
  type = object({
    project     = string
    service     = string
    target_time = optional(string, "")
  })

  validation {
    condition = alltrue([
      can(regex("^a-novel-recovery-[a-z0-9-]{1,13}[a-z0-9]$", var.recovery.project)),
      contains(["json-keys", "authentication", "genai"], var.recovery.service),
      var.recovery.target_time == "" || can(timecmp(var.recovery.target_time, "2000-01-01T00:00:00Z")),
    ])
    error_message = "The drill project must match a-novel-recovery-<id>, the service must have a cluster database, and a target time must be RFC 3339."
  }
}
