variable "access_policy_id" {
  description = "Number of the organization's Access Context Manager policy, which an organization admin creates and grants by hand."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.access_policy_id))
    error_message = "The access policy ID must be its number."
  }
}

# The restricted VIP serves any project's resources. The perimeter limits the production workloads'
# Google API calls to the workload project, and to management's secrets and backup buckets, so a
# poisoned dependency cannot copy data to another organization's resources.
locals {
  perimeter = {
    resources = ["projects/${google_project.workload.number}"]

    # Every API the perimeter's projects enable, plus Secret Manager, which their workloads call in
    # management, and the APIs GKE's nodes call. The VPC reaches only these, so an API missing here
    # fails closed. IAP's TCP forwarding stays out: its tunnel check reaches the perimeter without
    # the caller's identity, so only IAM tells an operator apart.
    restricted_services = [
      "artifactregistry.googleapis.com",
      "autoscaling.googleapis.com",
      "certificatemanager.googleapis.com",
      "cloudbuild.googleapis.com",
      "cloudquotas.googleapis.com",
      "cloudresourcemanager.googleapis.com",
      "cloudscheduler.googleapis.com",
      "cloudtrace.googleapis.com",
      "compute.googleapis.com",
      "container.googleapis.com",
      "containerregistry.googleapis.com",
      "dns.googleapis.com",
      "iam.googleapis.com",
      "iamcredentials.googleapis.com",
      "iap.googleapis.com",
      "kubernetesmetadata.googleapis.com",
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
      ci        = [for account in ["infra-foundation", "infra-plan"] : "serviceAccount:${account}@${var.management_project_id}.iam.gserviceaccount.com"]
      operators = setunion(var.database_operator_principals, var.authentication_maintenance_principals)
    }

    # Workloads read their secrets in management, and the databases write its backup buckets.
    # Any identity may call these two APIs there, since management holds only our own resources.
    egress_services = ["secretmanager.googleapis.com", "storage.googleapis.com"]
  }
}

# The perimeter enforces its status. Its dry-run spec repeats the status, so the policy audit log
# holds only refused calls. To try a rule before enforcing it, add it to the spec alone: the log then
# also holds the calls the spec would refuse.
#
# The spec stays explicit. The perimeter ran its spec in dry run before it enforced it, and Google
# keeps a spec until a request clears it, which the provider never sends. A spec beside
# use_explicit_dry_run_spec = false is refused, so the flag stays on.
resource "google_access_context_manager_service_perimeter" "production" {
  parent      = "accessPolicies/${var.access_policy_id}"
  name        = "accessPolicies/${var.access_policy_id}/servicePerimeters/a_novel_production"
  title       = "a-novel-production"
  description = "Keeps the production workloads' Google API calls inside production and management."

  use_explicit_dry_run_spec = true
  deletion_policy           = "PREVENT"

  status {
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

  lifecycle {
    prevent_destroy = true
  }
}
