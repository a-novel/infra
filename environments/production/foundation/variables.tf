variable "management_project_id" {
  description = "Stable Google Cloud project ID containing state, CI identities, and secret metadata."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.management_project_id))
    error_message = "The management project ID must be a valid 6-30 character Google Cloud project ID."
  }
}

variable "workload_project_id" {
  description = "Immutable Google Cloud project ID for the production workload."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.workload_project_id))
    error_message = "The workload project ID must be a valid 6-30 character Google Cloud project ID."
  }
}

variable "workload_project_name" {
  description = "Human-readable Google Cloud project name for the production workload."
  type        = string
  default     = "A-Novel production"

  validation {
    condition     = length(trimspace(var.workload_project_name)) >= 4 && length(var.workload_project_name) <= 30
    error_message = "The workload project name must contain 4-30 characters."
  }
}

variable "billing_account_id" {
  description = "Cloud Billing account ID linked to the production projects and used for their combined budget."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[0-9A-Z]{6}-[0-9A-Z]{6}-[0-9A-Z]{6}$", var.billing_account_id))
    error_message = "The billing account ID must use the XXXXXX-XXXXXX-XXXXXX format."
  }
}

variable "organization_id" {
  description = "Optional numeric organization ID under which automation creates the workload project."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.organization_id == null || can(regex("^[0-9]+$", var.organization_id))
    error_message = "The organization ID must be null or numeric."
  }
}

variable "folder_id" {
  description = "Optional numeric folder ID under which automation creates the workload project."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.folder_id == null || can(regex("^[0-9]+$", var.folder_id))
    error_message = "The folder ID must be null or numeric."
  }
}

variable "region" {
  description = "Google Cloud region for production resources."
  type        = string
  default     = "europe-west1"

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]+$", var.region))
    error_message = "The region must be a valid Google Cloud region name."
  }
}

variable "downtime" {
  description = "The planned downtime as JSON, from the DOWNTIME repository variable: components, start and end. Empty without one."
  type        = string
  default     = ""

  validation {
    condition     = var.downtime == "" || can(tolist(jsondecode(var.downtime).components)) && can(jsondecode(var.downtime).start) && can(jsondecode(var.downtime).end)
    error_message = "The planned downtime must be JSON with components, start and end."
  }
}

variable "cluster_region" {
  description = "Google Cloud region of the cluster and everything only it uses."
  type        = string

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]+$", var.cluster_region))
    error_message = "The cluster region must be a valid Google Cloud region name."
  }
}

variable "cluster_compute_cpu_quota" {
  description = "Compute Engine CPU ceiling in the cluster region: the nodes, at their maximum, plus one surge node."
  type        = number

  validation {
    condition     = var.cluster_compute_cpu_quota >= 4 && var.cluster_compute_cpu_quota <= 32 && floor(var.cluster_compute_cpu_quota) == var.cluster_compute_cpu_quota
    error_message = "The cluster CPU quota must be a whole number from 4 through 32."
  }
}

variable "cluster_ssd_quota_gb" {
  description = "SSD persistent disk ceiling in the cluster region, in GB: the nodes' boot disks and the databases' volumes."
  type        = number

  validation {
    condition     = var.cluster_ssd_quota_gb >= 100 && var.cluster_ssd_quota_gb <= 4000 && floor(var.cluster_ssd_quota_gb) == var.cluster_ssd_quota_gb
    error_message = "The cluster SSD quota must be a whole number of GB from 100 through 4000."
  }
}

variable "cluster" {
  description = "The production cluster's zones, the first holding the control plane, and its node pool."
  type = object({
    zones        = list(string)
    machine_type = string
    min_nodes    = number
    max_nodes    = number
  })

  validation {
    condition = (
      length(var.cluster.zones) >= 2 && alltrue([for zone in var.cluster.zones : startswith(zone, "${var.cluster_region}-")]) &&
      var.cluster.min_nodes >= 2 && var.cluster.max_nodes >= var.cluster.min_nodes
    )
    error_message = "The cluster needs two zones of its region and two nodes at least, since each database keeps its primary and replica on separate nodes."
  }
}

variable "cluster_ranges" {
  description = "Private IPv4 ranges of the cluster's network: the nodes' subnet, and the pods' and services' secondary ranges."
  type = object({
    nodes    = string
    pods     = string
    services = string
  })

  validation {
    condition     = alltrue([for range in values(var.cluster_ranges) : can(cidrhost(range, 0))])
    error_message = "Each cluster range must be a valid IPv4 CIDR."
  }
}

variable "database_operator_principals" {
  description = "Human identities allowed to read the workload project's resources, logs and alerts, and the cluster's service namespaces. Data Access logs remain restricted. Use user: or group: IAM member syntax."
  type        = set(string)

  validation {
    condition = (
      length(var.database_operator_principals) > 0 &&
      alltrue([
        for principal in var.database_operator_principals :
        can(regex("^(user|group):[^[:space:]@]+@[^[:space:]@]+$", principal))
      ])
    )
    error_message = "Provide at least one database operator as user:email or group:email. Service accounts and broad principals are not accepted."
  }
}

variable "authentication_maintenance_principals" {
  description = "Named human identities allowed to run Authentication's maintenance job with arguments. Use user: or group: IAM member syntax."
  type        = set(string)

  validation {
    condition = (
      length(var.authentication_maintenance_principals) > 0 &&
      alltrue([
        for principal in var.authentication_maintenance_principals :
        can(regex("^(user|group):[^[:space:]@]+@[^[:space:]@]+$", principal))
      ])
    )
    error_message = "Provide at least one Authentication maintenance operator as user:email or group:email. Service accounts and broad principals are not accepted."
  }
}

variable "cost_alert_email" {
  description = "Operator email address that receives production budget notifications and quota-review follow-up."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.cost_alert_email))
    error_message = "The cost alert recipient must be a valid email address."
  }
}

variable "operations_alert_email" {
  description = "Production-operator email address that receives service, job, backup, and database alerts plus a second copy of budget alerts."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.operations_alert_email))
    error_message = "The operations alert recipient must be a valid email address."
  }
}

variable "monthly_budget_units" {
  description = "Alert-only monthly production-infrastructure budget in whole units of the billing account currency; notifications do not stop spend."
  type        = number

  validation {
    condition     = var.monthly_budget_units >= 10 && var.monthly_budget_units <= 1000 && floor(var.monthly_budget_units) == var.monthly_budget_units
    error_message = "The monthly budget must be a whole billing-currency amount from 10 through 1000."
  }
}

variable "compute_cpu_quota" {
  description = "Compute Engine CPU ceiling in region, where no VM runs: it bounds a stray one's cost."
  type        = number

  validation {
    condition     = var.compute_cpu_quota >= 2 && var.compute_cpu_quota <= 32 && floor(var.compute_cpu_quota) == var.compute_cpu_quota
    error_message = "The Compute Engine CPU quota must be a whole number from 2 through 32."
  }
}
