mock_provider "google" {}

variables {
  service = "json-keys"
  region  = "europe-west1"
  target = {
    name       = "agora-json-keys-grpc"
    uri        = "https://agora-json-keys-grpc-abcdefghij-ew.a.run.app"
    status_rpc = "anovel.jsonkeys.v2.StatusService/Status"
  }
  image           = "europe-west1-docker.pkg.dev/a-novel-production-prod/agora-json-keys-private-production/service-json-keys/grpc@sha256:4f2a0c3f2d9e8b7a6c5d4e3f2a1b0c9d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a3b"
  service_account = "agora-json-keys-smoke@a-novel-production-prod.iam.gserviceaccount.com"
  network = {
    network    = "projects/a-novel-production-prod/global/networks/agora-production"
    subnetwork = "projects/a-novel-production-prod/regions/europe-west1/subnetworks/agora-production-europe-west1"
    tags       = ["agora-json-keys"]
  }
}

run "checks_as_the_identity_it_may_invoke_with" {
  command = plan

  assert {
    condition = (
      google_cloud_run_v2_service_iam_member.invoker.name == var.target.name &&
      google_cloud_run_v2_service_iam_member.invoker.member == "serviceAccount:${google_cloud_run_v2_job.smoke.template[0].template[0].service_account}"
    )
    error_message = "The job must run as the identity its service admits."
  }

  assert {
    condition     = !contains([for env in google_cloud_run_v2_job.smoke.template[0].template[0].containers[0].env : env.name], "DOWNTIME_START")
    error_message = "Without a planned downtime, the check receives no start."
  }
}

run "waits_for_a_planned_downtime_to_clear" {
  command = plan

  variables {
    downtime_start = "2026-10-12T06:00:00Z"
  }

  assert {
    condition     = lookup({ for env in google_cloud_run_v2_job.smoke.template[0].template[0].containers[0].env : env.name => env.value }, "DOWNTIME_START", null) == var.downtime_start
    error_message = "The check must know when the planned downtime starts, to skip during it."
  }

  assert {
    condition     = contains(terraform_data.smoke.triggers_replace, var.downtime_start)
    error_message = "A planned downtime must replace the trigger, so clearing it runs the check again."
  }
}
