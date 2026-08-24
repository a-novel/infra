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
  default     = "Agora production"

  validation {
    condition     = length(trimspace(var.workload_project_name)) >= 4 && length(var.workload_project_name) <= 30
    error_message = "The workload project name must contain 4-30 characters."
  }
}

variable "billing_account_id" {
  description = "Cloud Billing account ID linked to the workload project and used for its budget."
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
  description = "Private IPv4 range used by production VMs and Direct VPC egress."
  type        = string
  default     = "10.20.0.0/24"

  validation {
    condition     = can(cidrhost(var.subnet_cidr, 1)) && can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}/24$", var.subnet_cidr))
    error_message = "The production subnet must be a valid IPv4 /24 CIDR."
  }
}

variable "cost_alert_email" {
  description = "Operator email address that receives workload budget notifications."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.cost_alert_email))
    error_message = "The cost alert recipient must be a valid email address."
  }
}

variable "monthly_budget_units" {
  description = "Alert-only monthly workload budget in whole units of the billing account currency; notifications do not stop spend."
  type        = number
  default     = 60

  validation {
    condition     = var.monthly_budget_units >= 10 && var.monthly_budget_units <= 1000 && floor(var.monthly_budget_units) == var.monthly_budget_units
    error_message = "The monthly budget must be a whole billing-currency amount from 10 through 1000."
  }
}

variable "cloud_run_cpu_quota_millicpu" {
  description = "Regional Cloud Run CPU ceiling in milli-vCPU across services and jobs."
  type        = number
  default     = 8000

  validation {
    condition     = var.cloud_run_cpu_quota_millicpu >= 2000 && var.cloud_run_cpu_quota_millicpu <= 64000 && var.cloud_run_cpu_quota_millicpu % 1000 == 0
    error_message = "The Cloud Run CPU quota must be 2,000-64,000 milli-vCPU in 1,000 milli-vCPU increments."
  }
}

variable "cloud_run_memory_quota_bytes" {
  description = "Regional Cloud Run memory ceiling in bytes across services and jobs."
  type        = number
  default     = 17179869184

  validation {
    condition     = var.cloud_run_memory_quota_bytes >= 4294967296 && var.cloud_run_memory_quota_bytes <= 137438953472 && var.cloud_run_memory_quota_bytes % 1073741824 == 0
    error_message = "The Cloud Run memory quota must be 4-128 GiB in whole GiB increments."
  }
}

variable "cloud_run_direct_vpc_instance_quota" {
  description = "Regional ceiling for Cloud Run instances using Direct VPC egress."
  type        = number
  default     = 20

  validation {
    condition     = var.cloud_run_direct_vpc_instance_quota >= 2 && var.cloud_run_direct_vpc_instance_quota <= 100 && floor(var.cloud_run_direct_vpc_instance_quota) == var.cloud_run_direct_vpc_instance_quota
    error_message = "The Direct VPC instance quota must be a whole number from 2 through 100."
  }
}

variable "compute_cpu_quota" {
  description = "Regional Compute Engine CPU ceiling for the stateful data plane."
  type        = number
  default     = 4

  validation {
    condition     = var.compute_cpu_quota >= 2 && var.compute_cpu_quota <= 32 && floor(var.compute_cpu_quota) == var.compute_cpu_quota
    error_message = "The Compute Engine CPU quota must be a whole number from 2 through 32."
  }
}
