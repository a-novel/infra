# Plans the committed inputs against mocked providers and foundation's mocked outputs.
mock_provider "google" {}
mock_provider "kubernetes" {}
mock_provider "helm" {}

override_data {
  target = data.terraform_remote_state.foundation
  values = {
    outputs = {
      region              = "europe-west1"
      workload_project_id = "a-novel-production-prod"
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

run "isolates_every_namespace" {
  command = plan

  assert {
    condition = alltrue([for namespace in concat(values(kubernetes_namespace_v1.service), values(kubernetes_namespace_v1.addon)) :
      one(namespace.metadata).labels["pod-security.kubernetes.io/enforce"] == "restricted"
    ])
    error_message = "Every namespace this root manages must enforce Pod Security's restricted level."
  }

  assert {
    condition = alltrue([for binding in kubernetes_manifest.admission_binding :
      binding.manifest.spec.validationActions == ["Deny"] &&
      toset(one(binding.manifest.spec.matchResources.namespaceSelector.matchExpressions).values) == setunion(var.namespaces, local.addon_namespaces)
    ])
    error_message = "Every admission policy must deny, in every namespace this root manages."
  }

  assert {
    condition = (
      strcontains(kubernetes_manifest.admission_policy["a-novel-images"].manifest.spec.validations[0].expression, "startsWith('europe-west1-docker.pkg.dev/a-novel-production-prod/')") &&
      toset(keys(kubernetes_network_policy_v1.default_deny)) == toset(var.namespaces) &&
      alltrue([for policy in kubernetes_network_policy_v1.default_deny : toset(one(policy.spec).policy_types) == toset(["Ingress", "Egress"])])
    )
    error_message = "Pods may pull only from our Artifact Registry, and every service namespace must deny all traffic by default."
  }
}
