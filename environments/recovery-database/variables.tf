variable "recovery" {
  description = "The drill, from recovery.yaml's drill input: its disposable project, the services whose databases it restores, every one by default, and the time to recover to, empty for the latest."
  type = object({
    project     = string
    services    = optional(set(string), ["authentication", "genai", "json-keys"])
    target_time = optional(string, "")
  })

  validation {
    condition = alltrue([
      can(regex("^a-novel-recovery-[a-z0-9-]{1,13}[a-z0-9]$", var.recovery.project)),
      length(var.recovery.services) > 0,
      alltrue([for service in var.recovery.services : contains(["authentication", "genai", "json-keys"], service)]),
      var.recovery.target_time == "" || can(timecmp(var.recovery.target_time, "2000-01-01T00:00:00Z")),
    ])
    error_message = "The drill project must match a-novel-recovery-<id>, each service must have a cluster database, and a target time must be RFC 3339."
  }
}
