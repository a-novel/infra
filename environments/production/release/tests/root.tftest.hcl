mock_provider "google" {}

variables {
  workload_project_id = "agora-production-test"
}

run "relinquishes_ownership_without_deleting_resources" {
  command = plan

  assert {
    condition     = output.root_name == "release" && output.region == "europe-west1"
    error_message = "Retain exact custody coordinates until the ownership transfer finishes."
  }

  assert {
    condition = alltrue([for address in [
      "google_cloud_scheduler_job.json_keys_rotation",
      "google_tags_location_tag_binding.application",
      "google_tags_location_tag_binding.json_keys",
      "google_tags_location_tag_binding.json_keys_smoke",
      ] : can(regex(
        format("(?s)from\\s*=\\s*%s\\s+lifecycle\\s*{\\s*destroy\\s*=\\s*false", replace(address, ".", "\\.")),
        file("${path.module}/application.tf")
    ))])
    error_message = "Every retained resource must leave state without deleting its live object."
  }
}
