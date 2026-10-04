mock_provider "google-beta" {
  mock_resource "google_project_service_identity" {
    defaults = { member = "serviceAccount:service-111111111111@serverless-robot-prod.iam.gserviceaccount.com" }
  }
}

mock_provider "google" {
  mock_resource "google_project" {
    defaults = { number = "987654321098" }
  }
  mock_resource "google_service_account" {
    defaults = {
      email = "runtime-mock@agora-production-test.iam.gserviceaccount.com"
      name  = "projects/agora-production-test/serviceAccounts/runtime-mock@agora-production-test.iam.gserviceaccount.com"
    }
  }
  mock_resource "google_tags_tag_key" {
    defaults = { id = "tagKeys/100000000001", name = "100000000001" }
  }
  mock_resource "google_tags_tag_value" {
    defaults = { id = "tagValues/200000000001", name = "200000000001" }
  }
  mock_resource "google_monitoring_notification_channel" {
    defaults = { name = "projects/agora-production-test/notificationChannels/cost-email" }
  }
  mock_data "google_billing_account" {
    defaults = { currency_code = "EUR" }
  }
  mock_data "google_project" {
    defaults = { number = "123456789012" }
  }
}

variables {
  management_project_id                 = "agora-management-test"
  workload_project_id                   = "agora-production-test"
  adopt_default_network                 = false
  backup_bucket_name                    = "agora-management-test-123456789012-backups"
  billing_account_id                    = "ABCDEF-123456-ABCDEF"
  cost_alert_email                      = "infra@example.com"
  operations_alert_email                = "operations@example.com"
  organization_id                       = "123456789012"
  database_operator_principals          = ["group:infra-operators@example.com"]
  authentication_initializer_principals = ["group:authentication-initializers@example.com"]
}

run "disabled_by_default" {
  command = plan
  assert {
    condition     = length(module.public_project) == 0 && length(module.public_api_project) == 0 && length(google_compute_shared_vpc_service_project.public_api) == 0 && output.production_projects == null
    error_message = "Existing inputs must create no public shell or placement output."
  }
}

run "retain_host_without_dedicated_projects" {
  command = plan
  variables { shared_vpc_enabled = true }
  assert {
    condition     = length(module.public_project) == 0 && google_compute_shared_vpc_host_project.production[0].project == var.workload_project_id && google_compute_shared_vpc_host_project.production[0].deletion_policy == "PREVENT"
    error_message = "Shared VPC retention must be independent of dedicated projects."
  }
}

run "optional_public_shell" {
  command = plan
  variables {
    public_project_id = "agora-public-test"
  }
  override_resource {
    target = module.public_project["public"].google_project.service
    values = { number = "222222222222" }
  }
  assert {
    condition     = length(module.public_project) == 1 && length(module.public_api_project) == 0 && length(google_compute_shared_vpc_service_project.public_api) == 0 && length(google_compute_shared_vpc_host_project.production) == 0 && length(google_project_iam_custom_role.foundation_public_api) == 0
    error_message = "A platform shell must neither attach to private Shared VPC nor require its host activation."
  }
  assert {
    condition     = output.production_projects.private.project_id == var.workload_project_id && output.production_projects.public.project_id == var.public_project_id && output.production_projects.public.project_number == "222222222222"
    error_message = "Coordinates must preserve the existing workload project and identify the public shell."
  }
  assert {
    condition     = length(module.service_project) == 0 && length(google_compute_subnetwork_iam_member.service_run) == 0 && length(google_compute_subnetwork_iam_member.service_mig) == 0 && length(google_compute_subnetwork_iam_member.service_foundation) == 0
    error_message = "The public shell must not enroll a service release or grant access to the database subnet."
  }
  assert {
    condition     = google_billing_budget.workload[0].budget_filter[0].projects == toset(["projects/123456789012", "projects/987654321098", "projects/222222222222"]) && google_billing_budget.workload[0].amount[0].specified_amount[0].units == tostring(var.monthly_budget_units)
    error_message = "The public shell must join the existing budget without increasing its amount."
  }
}

run "reject_management_project" {
  command = plan
  variables {
    shared_vpc_enabled = true
    public_project_id  = "agora-management-test"
  }
  expect_failures = [var.public_project_id]
}

run "reject_workload_project" {
  command = plan
  variables {
    shared_vpc_enabled = true
    public_project_id  = "agora-production-test"
  }
  expect_failures = [var.public_project_id]
}

run "reject_invalid_project" {
  command = plan
  variables {
    shared_vpc_enabled = true
    public_project_id  = "INVALID"
  }
  expect_failures = [var.public_project_id]
}

run "reject_api_implicit_host" {
  command = plan
  variables { public_api_project_id = "agora-api-test" }
  expect_failures = [var.public_api_project_id]
}

run "reject_dedicated_registration" {
  command = plan
  variables {
    shared_vpc_enabled = true
    public_project_id  = "agora-public-test"
    service_projects   = { json-keys = "agora-json-keys-test" }
  }
  expect_failures = [var.public_project_id]
}

run "reject_recovery_host" {
  command = plan
  variables {
    recovery_mode      = true
    shared_vpc_enabled = true
  }
  expect_failures = [var.shared_vpc_enabled]
}

run "reject_recovery_public_project" {
  command = plan
  variables {
    recovery_mode     = true
    public_project_id = "agora-public-test"
  }
  expect_failures = [var.public_project_id]
}

run "three_project_coordinates" {
  command = plan
  variables {
    shared_vpc_enabled    = true
    public_project_id     = "agora-public-test"
    public_api_project_id = "agora-api-test"
  }
  override_resource {
    target = module.public_project["public"].google_project.service
    values = { number = "222222222222" }
  }
  override_resource {
    target = module.public_api_project["public-api"].google_project.service
    values = { number = "333333333333" }
  }
  assert {
    condition = (
      keys(output.production_projects) == ["private", "public", "public-api"] &&
      output.production_projects.private.project_id == var.workload_project_id &&
      output.production_projects.public.project_id == var.public_project_id &&
      output.production_projects.public-api.project_id == var.public_api_project_id &&
      length(google_compute_shared_vpc_service_project.public_api) == 1 &&
      google_compute_shared_vpc_service_project.public_api["public-api"].host_project == var.workload_project_id &&
      google_compute_shared_vpc_service_project.public_api["public-api"].service_project == var.public_api_project_id
    )
    error_message = "Only the API project may attach to the existing private network; platform and management projects remain distinct."
  }
  assert {
    condition = (
      length(module.service_release) == 0 && length(module.service_project) == 0 &&
      length(google_project_iam_custom_role.foundation_public_api) == 0 && length(google_project_service.public_api_telemetry) == 0 &&
      length(google_project_iam_member.public_api_network_viewer) == 0 && length(google_compute_subnetwork_iam_member.public_api_run) == 0 &&
      length(google_compute_subnetwork_iam_member.service_run) == 0 &&
      length(google_compute_subnetwork_iam_member.service_mig) == 0 &&
      length(google_compute_subnetwork_iam_member.service_foundation) == 0 &&
      google_billing_budget.workload[0].budget_filter[0].projects == toset(["projects/123456789012", "projects/987654321098", "projects/222222222222", "projects/333333333333"]) &&
      google_billing_budget.workload[0].amount[0].specified_amount[0].units == tostring(var.monthly_budget_units)
    )
    error_message = "Project shells must only extend existing budget coverage, with no service or private subnet access."
  }
}

run "reject_api_platform_collision" {
  command = plan
  variables {
    shared_vpc_enabled    = true
    public_project_id     = "agora-public-test"
    public_api_project_id = "agora-public-test"
  }
  expect_failures = [var.public_api_project_id]
}

run "reject_api_management_collision" {
  command = plan
  variables {
    shared_vpc_enabled    = true
    public_api_project_id = "agora-management-test"
  }
  expect_failures = [var.public_api_project_id]
}

run "reject_api_private_collision" {
  command = plan
  variables {
    shared_vpc_enabled    = true
    public_api_project_id = "agora-production-test"
  }
  expect_failures = [var.public_api_project_id]
}

run "reject_api_invalid_project" {
  command = plan
  variables {
    shared_vpc_enabled    = true
    public_api_project_id = "INVALID"
  }
  expect_failures = [var.public_api_project_id]
}

run "reject_recovery_api_project" {
  command = plan
  variables {
    recovery_mode         = true
    public_api_project_id = "agora-api-test"
  }
  expect_failures = [var.public_api_project_id]
}

run "reject_api_dedicated_registration" {
  command = plan
  variables {
    shared_vpc_enabled    = true
    public_api_project_id = "agora-api-test"
    service_projects      = { json-keys = "agora-json-keys-test" }
  }
  expect_failures = [var.public_api_project_id]
}

run "reject_service_platform_placement" {
  command = plan
  variables {
    shared_vpc_enabled    = true
    public_project_id     = "agora-public-test"
    public_api_project_id = "agora-api-test"
    service_release_zones = { json-keys = ["public"] }
  }
  expect_failures = [var.service_release_zones]
}
