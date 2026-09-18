resource "google_clouddeploy_target" "service" {
  project          = var.project_id
  location         = var.region
  name             = var.name
  require_approval = true
  deletion_policy  = "PREVENT"

  run {
    location = "projects/${var.project_id}/locations/${var.region}"
  }

  dynamic "execution_configs" {
    for_each = {
      deploy = ["RENDER", "DEPLOY"]
      verify = ["VERIFY"]
    }
    content {
      usages            = execution_configs.value
      service_account   = local.workers[execution_configs.key]
      artifact_storage  = "gs://${google_storage_bucket.artifacts.name}/cloud-deploy/${var.project_id}/${var.name}"
      execution_timeout = "600s"
      verbose           = false
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_clouddeploy_delivery_pipeline" "service" {
  project         = var.project_id
  location        = var.region
  name            = var.name
  deletion_policy = "PREVENT"

  # Activation needs the private verifier and a reviewed one-writer handoff.
  # Do not turn this into a caller-controlled bypass of those gates.
  suspended = true

  serial_pipeline {
    stages {
      target_id = google_clouddeploy_target.service.name

      strategy {
        canary {
          runtime_config {
            cloud_run {
              automatic_traffic_control = true
              canary_revision_tags      = ["candidate"]
              stable_revision_tags      = ["stable"]
            }
          }

          canary_deployment {
            percentages = [0]

            # Cloud Deploy adds verification to the candidate and stable phases.
            # Database mutations must never become automatically retried hooks.
            verify_config {
              tasks {
                container {
                  image = var.verification_image
                  env = {
                    EXPECTED_PROJECT_ID     = var.project_id
                    EXPECTED_REGION         = var.region
                    EXPECTED_SERVICE        = var.name
                    EXPECTED_PROBE_ACCOUNT  = google_service_account.execution["probe"].email
                    EXPECTED_VERIFIER_IMAGE = var.verification_image
                    EXPECTED_PROBE_NETWORK  = var.probe.network
                    EXPECTED_PROBE_SUBNET   = var.probe.subnetwork
                  }
                }
              }
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
