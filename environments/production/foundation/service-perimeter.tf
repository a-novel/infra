variable "access_policy_id" {
  description = "Number of the organization's Access Context Manager policy, which an organization admin creates and grants by hand."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.access_policy_id))
    error_message = "The access policy ID must be its number."
  }
}

# The restricted VIP serves any project's resources. The perimeter limits the production workloads'
# Google API calls to the private and public-api projects, and to management's secrets and backup
# buckets, so a poisoned dependency cannot copy data to another organization's resources.
locals {
  perimeter = {
    resources = [for number in concat([google_project.workload.number], [for project in module.public_api_project : project.project_number]) : "projects/${number}"]

    # Every API the perimeter's projects enable, plus Secret Manager, which their workloads call in
    # management. The VPC reaches only these, so an API missing here fails closed. IAP's TCP
    # forwarding stays out: its tunnel check reaches the perimeter without the caller's identity, so
    # only IAM tells an operator apart.
    restricted_services = [
      "artifactregistry.googleapis.com",
      "cloudbuild.googleapis.com",
      "cloudquotas.googleapis.com",
      "cloudresourcemanager.googleapis.com",
      "cloudscheduler.googleapis.com",
      "cloudtrace.googleapis.com",
      "compute.googleapis.com",
      "dns.googleapis.com",
      "iam.googleapis.com",
      "iamcredentials.googleapis.com",
      "iap.googleapis.com",
      "logging.googleapis.com",
      "monitoring.googleapis.com",
      "networksecurity.googleapis.com",
      "oslogin.googleapis.com",
      "run.googleapis.com",
      "secretmanager.googleapis.com",
      "serviceusage.googleapis.com",
      "storage.googleapis.com",
      "sts.googleapis.com",
      "telemetry.googleapis.com",
      "workflows.googleapis.com",
    ]

    # GitHub-hosted runners have no fixed addresses, so CI enters from any source as its own
    # identities, and IAM bounds what each may do.
    ingress = {
      ci        = [for account in ["infra-foundation", "infra-plan", "infra-health"] : "serviceAccount:${account}@${var.management_project_id}.iam.gserviceaccount.com"]
      operators = setunion(var.database_operator_principals, var.authentication_maintenance_principals)
    }

    # Workloads read their secrets in management, and the repository VMs write its backup buckets.
    # Any identity may call these two APIs there, since management holds only our own resources.
    egress_services = ["secretmanager.googleapis.com", "storage.googleapis.com"]
  }
}

# The spec runs in dry run and logs the calls it would refuse. The perimeter has no status, so it
# refuses nothing: an empty status block never converges.
resource "google_access_context_manager_service_perimeter" "production" {
  parent      = "accessPolicies/${var.access_policy_id}"
  name        = "accessPolicies/${var.access_policy_id}/servicePerimeters/a_novel_production"
  title       = "a-novel-production"
  description = "Keeps the production workloads' Google API calls inside production and management."

  use_explicit_dry_run_spec = true
  deletion_policy           = "PREVENT"

  spec {
    resources           = local.perimeter.resources
    restricted_services = local.perimeter.restricted_services

    vpc_accessible_services {
      enable_restriction = true
      allowed_services   = ["RESTRICTED-SERVICES"]
    }

    dynamic "ingress_policies" {
      for_each = local.perimeter.ingress

      content {
        title = ingress_policies.key

        ingress_from {
          identities = ingress_policies.value

          sources {
            access_level = "*"
          }
        }

        ingress_to {
          resources = ["*"]

          operations {
            service_name = "*"
          }
        }
      }
    }

    egress_policies {
      title = "management"

      egress_from {
        identity_type = "ANY_IDENTITY"
      }

      egress_to {
        resources = ["projects/${data.google_project.management.number}"]

        dynamic "operations" {
          for_each = local.perimeter.egress_services

          content {
            service_name = operations.value

            method_selectors {
              method = "*"
            }
          }
        }
      }
    }
  }

  # prevent_destroy returns once the rename has applied: it would refuse the replacement
  # (a-novel/infra#1083).
}
