mock_provider "helm" {}

variables {
  namespaces = { cert_manager = "cert-manager", cloudnative_pg = "cnpg-system" }
  images = {
    for name in ["cert_manager_controller", "cert_manager_webhook", "cert_manager_cainjector", "cloudnative_pg", "plugin_barman_cloud", "plugin_barman_cloud_sidecar"] :
    name => { repository = "europe-west9-docker.pkg.dev/a-novel-recovery-test/ghcr-io/${name}", tag = "1.0.0@sha256:${sha256(name)}" }
  }
}

run "pulls_every_image_from_the_callers_registry" {
  command = plan

  assert {
    condition = alltrue([for release in [helm_release.cert_manager, helm_release.cloudnative_pg, helm_release.plugin_barman_cloud] :
      strcontains(join("\n", release.values), "europe-west9-docker.pkg.dev") &&
      !strcontains(join("\n", release.values), "quay.io/") && !strcontains(join("\n", release.values), "ghcr.io/")
    ])
    error_message = "Every chart must pull its images from the caller's registry, and keep no upstream reference."
  }

  assert {
    condition = alltrue([for key in ["image", "sidecarImage"] :
      yamldecode(helm_release.plugin_barman_cloud.values[0])[key].registry == "europe-west9-docker.pkg.dev" &&
      yamldecode(helm_release.plugin_barman_cloud.values[0])[key].repository == "a-novel-recovery-test/ghcr-io/${key == "image" ? "plugin_barman_cloud" : "plugin_barman_cloud_sidecar"}"
    ])
    error_message = "The plugin's chart takes its registry apart from the repository."
  }
}
