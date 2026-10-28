# Plans the committed inputs against mocked providers and foundation's mocked outputs.
mock_provider "google" {}
mock_provider "kubernetes" {}
mock_provider "helm" {}

override_data {
  target = data.terraform_remote_state.foundation
  values = {
    outputs = {
      cluster = {
        dns_endpoint = "gke-mock.europe-west1-d.gke.goog"
        image_registries = {
          "ghcr.io" = "europe-west1-docker.pkg.dev/a-novel-production-prod/a-novel-ghcr-io"
          "quay.io" = "europe-west1-docker.pkg.dev/a-novel-production-prod/a-novel-quay-io"
        }
      }
    }
  }
}

run "pulls_addons_through_our_registry" {
  command = plan

  assert {
    condition = alltrue([for image in values(local.images) :
      startswith(image.repository, "europe-west1-docker.pkg.dev/a-novel-production-prod/") && can(regex("@sha256:[a-f0-9]{64}$", image.tag))
    ])
    error_message = "Every add-on image must pull through our Artifact Registry, pinned by digest."
  }

  assert {
    condition = alltrue([for release in [helm_release.cert_manager, helm_release.cloudnative_pg, helm_release.plugin_barman_cloud, helm_release.external_secrets] :
      !strcontains(join("\n", release.values), "quay.io/") && !strcontains(join("\n", release.values), "ghcr.io/")
    ])
    error_message = "No chart may keep an upstream registry reference."
  }
}
