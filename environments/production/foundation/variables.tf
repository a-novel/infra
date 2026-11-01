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

variable "subnet_cidr" {
  description = "Private IPv4 range of the production VMs and of the Direct VPC egress that stays inside Google."
  type        = string
  default     = "10.20.0.0/24"

  validation {
    condition     = can(cidrhost(var.subnet_cidr, 1)) && can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}/24$", var.subnet_cidr))
    error_message = "The production subnet must be a valid IPv4 /24 CIDR."
  }
}

variable "egress_subnet_cidr" {
  description = "Private IPv4 range of the Direct VPC egress that Cloud NAT serves: the workloads in the egress allowlist."
  type        = string
  default     = "10.20.1.0/24"

  validation {
    condition = (
      can(cidrhost(var.egress_subnet_cidr, 1)) && tonumber(split("/", var.egress_subnet_cidr)[1]) <= 26 &&
      !cidrcontains(var.subnet_cidr, cidrhost(var.egress_subnet_cidr, 0)) &&
      !cidrcontains(var.egress_subnet_cidr, cidrhost(var.subnet_cidr, 0))
    )
    error_message = "The egress subnet must be a valid IPv4 CIDR of /26 or larger, Direct VPC egress's minimum, apart from the production subnet."
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
  description = "Google Cloud region of the cluster and everything only it uses. The Cloud Run platform keeps region until it retires."
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

variable "sentry_ingest_host" {
  description = "Ingest host of the Sentry organization the services report to, the one Sentry name the egress allowlist admits."
  type        = string

  validation {
    condition     = can(regex("^o[0-9]+\\.ingest\\.[a-z]+\\.sentry\\.io$", var.sentry_ingest_host))
    error_message = "Name one organization's ingest host, o<id>.ingest.<region>.sentry.io, never a wider Sentry domain."
  }
}

variable "database_operator_principals" {
  description = "Human identities allowed to inspect the private database host through OS Login and IAP, read workload logs, and read the cluster's service namespaces. Data Access logs remain restricted. Use user: or group: IAM member syntax."
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

variable "cloud_run_cpu_quota_millicpu" {
  description = "Regional Cloud Run CPU ceiling in milli-vCPU across services and jobs."
  type        = number

  validation {
    condition     = var.cloud_run_cpu_quota_millicpu >= 2000 && var.cloud_run_cpu_quota_millicpu <= 64000 && var.cloud_run_cpu_quota_millicpu % 1000 == 0
    error_message = "The Cloud Run CPU quota must be 2,000-64,000 milli-vCPU in 1,000 milli-vCPU increments."
  }
}

variable "cloud_run_memory_quota_bytes" {
  description = "Regional Cloud Run memory ceiling in bytes across services and jobs."
  type        = number

  validation {
    condition     = var.cloud_run_memory_quota_bytes >= 4294967296 && var.cloud_run_memory_quota_bytes <= 137438953472 && var.cloud_run_memory_quota_bytes % 1073741824 == 0
    error_message = "The Cloud Run memory quota must be 4-128 GiB in whole GiB increments."
  }
}

variable "shell_cloud_run_quota" {
  description = "Regional Cloud Run ceiling of each shell project, in milli-vCPU and memory bytes. It must fit each shell's services' max instances plus one rollout instance."
  type = object({
    cpu_millicpu = number
    memory_bytes = number
  })
  # Google refuses a ceiling below recent usage, and Authentication has used 3 vCPU.
  default = { cpu_millicpu = 3000, memory_bytes = 4294967296 }

  validation {
    condition = (
      var.shell_cloud_run_quota.cpu_millicpu >= 2000 && var.shell_cloud_run_quota.cpu_millicpu <= 64000 &&
      var.shell_cloud_run_quota.cpu_millicpu % 1000 == 0 &&
      var.shell_cloud_run_quota.memory_bytes >= 4294967296 && var.shell_cloud_run_quota.memory_bytes <= 137438953472 &&
      var.shell_cloud_run_quota.memory_bytes % 1073741824 == 0
    )
    error_message = "The shell Cloud Run quota must be 2,000-64,000 milli-vCPU in 1,000 increments and 4-128 GiB in whole GiB."
  }
}

variable "compute_cpu_quota" {
  description = "Regional Compute Engine CPU ceiling for the database hosts, their backup repositories and the cluster's nodes."
  type        = number

  validation {
    condition     = var.compute_cpu_quota >= 2 && var.compute_cpu_quota <= 32 && floor(var.compute_cpu_quota) == var.compute_cpu_quota
    error_message = "The Compute Engine CPU quota must be a whole number from 2 through 32."
  }
}

