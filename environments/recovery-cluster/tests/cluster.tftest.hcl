mock_provider "google" {
  mock_resource "google_service_account" {
    defaults = {
      email  = "recovery-nodes@a-novel-recovery-261101.iam.gserviceaccount.com"
      member = "serviceAccount:recovery-nodes@a-novel-recovery-261101.iam.gserviceaccount.com"
    }
  }
}

override_data {
  target = data.terraform_remote_state.bootstrap
  values = {
    outputs = {
      barman_buckets = {
        authentication = "a-novel-management-prod-232403541574-barman-authentication"
        genai          = "a-novel-management-prod-232403541574-barman-genai"
        json-keys      = "a-novel-management-prod-232403541574-barman-json-keys"
      }
      barman_reader_role = "projects/a-novel-management-prod/roles/barmanReader"
    }
  }
}

override_data {
  target = data.google_project.drill
  values = {
    number = "123456789012"
  }
}

variables {
  recovery = { project = "a-novel-recovery-261101", service = "genai" }
}

run "isolates_the_drill" {
  command = plan

  assert {
    condition = (
      google_compute_network.drill.delete_default_routes_on_create &&
      toset([for route in google_compute_route.google_apis : route.dest_range]) == toset(local.google_api_ranges) &&
      google_compute_firewall.deny_egress.destination_ranges == toset(["0.0.0.0/0"]) &&
      google_compute_firewall.allow_google_apis.destination_ranges == toset(local.google_api_ranges)
    )
    error_message = "The drill must reach nothing but Google's restricted APIs."
  }

  assert {
    condition = (
      one(google_container_cluster.drill.private_cluster_config).enable_private_nodes &&
      one(google_container_cluster.drill.private_cluster_config).enable_private_endpoint &&
      !google_container_cluster.drill.deletion_protection &&
      one(one(google_container_node_pool.drill.node_config).workload_metadata_config).mode == "GKE_METADATA"
    )
    error_message = "The drill cluster must keep its nodes and endpoint private, give pods their own identity, and go with the drill."
  }
}

run "reads_only_the_restored_service_backups" {
  command = plan

  assert {
    condition = (
      google_storage_bucket_iam_member.backups.bucket == "a-novel-management-prod-232403541574-barman-genai" &&
      google_storage_bucket_iam_member.backups.role == "projects/a-novel-management-prod/roles/barmanReader" &&
      google_storage_bucket_iam_member.backups.member == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/a-novel-recovery-261101.svc.id.goog/subject/ns/genai/sa/drill"
    )
    error_message = "Only the drill's database may read, and only its service's backups."
  }
}

run "refuses_a_protected_project" {
  command = plan

  variables {
    recovery = { project = "a-novel-production-prod", service = "genai" }
  }

  expect_failures = [var.recovery]
}
