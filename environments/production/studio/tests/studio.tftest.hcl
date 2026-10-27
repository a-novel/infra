mock_provider "google" {
  mock_resource "google_service_account" {
    defaults = {
      email  = "agora-studio-public@a-novel-public-prod.iam.gserviceaccount.com"
      member = "serviceAccount:agora-studio-public@a-novel-public-prod.iam.gserviceaccount.com"
      name   = "projects/a-novel-public-prod/serviceAccounts/agora-studio-public@a-novel-public-prod.iam.gserviceaccount.com"
    }
  }
  mock_data "google_cloud_run_v2_service" {
    defaults = { uri = "https://agora-authentication-rest-test-ew.a.run.app" }
  }
}

override_data {
  target = data.terraform_remote_state.foundation
  values = {
    outputs = {
      region               = "europe-west1"
      sentry_ingest_host   = "o1.ingest.us.sentry.io"
      cloud_run_cpu_quotas = { private = 8000, public = 3000, "public-api" = 3000 }
      production_projects = {
        private      = { project_id = "a-novel-production-prod" }
        public       = { project_id = "a-novel-public-prod" }
        "public-api" = { project_id = "a-novel-public-api-prod" }
      }
    }
  }
}

override_data {
  target = data.terraform_remote_state.sentry
  values = {
    outputs = {
      services = {
        "platform-studio" = {
          project_id   = "4512319614156801"
          dsn          = "https://def456@o1.ingest.us.sentry.io/4512319614156801"
          otlp_headers = "x-sentry-auth=sentry sentry_key=def456"
        }
      }
    }
  }
}

run "serves_only_through_the_load_balancer" {
  command = plan

  assert {
    condition     = local.project_id == "a-novel-public-prod"
    error_message = "Studio is a platform: it runs in the public project, outside the VPC and the perimeter."
  }

  assert {
    condition = (
      google_cloud_run_v2_service.web.ingress == "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER" &&
      google_cloud_run_v2_service.web.invoker_iam_disabled
    )
    error_message = "The service admits requests without IAM only because nothing but the load balancer can reach it."
  }

  assert {
    condition = (
      google_compute_ssl_policy.web.min_tls_version == "TLS_1_2" &&
      google_compute_url_map.redirect.default_url_redirect[0].https_redirect
    )
    error_message = "Visitors get TLS 1.2 or later, and plain HTTP only redirects to HTTPS."
  }
}

run "traces_the_server_over_otlp" {
  command = plan

  assert {
    condition = (
      lookup({ for env in google_cloud_run_v2_service.web.template[0].containers[0].env : env.name => env.value }, "OTEL_RESOURCE_ATTRIBUTES", null) == "a_novel.workload=api" &&
      !anytrue([for env in google_cloud_run_v2_service.web.template[0].containers[0].env : startswith(env.name, "SENTRY_")])
    )
    error_message = "Studio's server spans carry the workload label Sentry's monitors read, and no Sentry SDK runs on its server."
  }
}

run "refuses_instances_beyond_the_quota" {
  command = plan

  override_data {
    target = data.terraform_remote_state.foundation
    values = {
      outputs = {
        region               = "europe-west1"
        sentry_ingest_host   = "o1.ingest.us.sentry.io"
        cloud_run_cpu_quotas = { private = 8000, public = 2000, "public-api" = 3000 }
        production_projects = {
          private      = { project_id = "a-novel-production-prod" }
          public       = { project_id = "a-novel-public-prod" }
          "public-api" = { project_id = "a-novel-public-api-prod" }
        }
      }
    }
  }

  expect_failures = [google_cloud_run_v2_service.web]
}
