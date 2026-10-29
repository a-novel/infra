# Plans the committed inputs against mocked providers and foundation's mocked outputs.
mock_provider "google" {}
mock_provider "kubernetes" {}
mock_provider "helm" {}

# Tests cannot import.
variables {
  adopted_databases = []
}

override_data {
  target = data.terraform_remote_state.foundation
  values = {
    outputs = {
      region              = "europe-west1"
      workload_project_id = "a-novel-production-prod"
      cluster = {
        dns_endpoint      = "gke-mock.europe-west1-d.gke.goog"
        node_range        = "10.30.0.0/24"
        google_api_ranges = ["199.36.153.4/30", "34.126.0.0/18"]
        database_images = {
          authentication = "europe-west1-docker.pkg.dev/a-novel-production-prod/agora-authentication-private-production/service-authentication/database@sha256:1111111111111111111111111111111111111111111111111111111111111111"
          genai          = "europe-west1-docker.pkg.dev/a-novel-production-prod/agora-genai-private-production/service-genai/database@sha256:2222222222222222222222222222222222222222222222222222222222222222"
          json-keys      = "europe-west1-docker.pkg.dev/a-novel-production-prod/agora-json-keys-private-production/service-json-keys/database@sha256:3333333333333333333333333333333333333333333333333333333333333333"
        }
        image_registries = {
          "ghcr.io" = "europe-west1-docker.pkg.dev/a-novel-production-prod/a-novel-ghcr-io"
          "quay.io" = "europe-west1-docker.pkg.dev/a-novel-production-prod/a-novel-quay-io"
        }
      }
    }
  }
}

override_data {
  target = data.terraform_remote_state.bootstrap
  values = {
    outputs = {
      barman_buckets = {
        authentication = "mock-barman-authentication"
        genai          = "mock-barman-genai"
        json-keys      = "mock-barman-json-keys"
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
      strcontains(kubernetes_manifest.admission_policy["a-novel-images"].manifest.spec.validations[0].expression, "matches('^[a-z0-9-]+-docker[.]pkg[.]dev/a-novel-production-prod/')") &&
      toset(keys(kubernetes_network_policy_v1.default_deny)) == toset(var.namespaces) &&
      alltrue([for policy in kubernetes_network_policy_v1.default_deny : toset(one(policy.spec).policy_types) == toset(["Ingress", "Egress"])]) &&
      alltrue([for policy in kubernetes_network_policy_v1.default_deny :
        toset(one(one(one(one(policy.spec).egress).to).pod_selector).match_expressions[0].values) == toset(["kube-dns", "node-local-dns"])
      ])
    )
    error_message = "Pods may pull only from our Artifact Registry, every service namespace must deny all traffic by default, and its pods must reach the node's DNS cache."
  }
}

run "keeps_each_database_available_and_backed_up" {
  command = plan

  variables {
    custom_resources = true
  }

  assert {
    condition = alltrue([for service, database in kubernetes_manifest.database :
      database.manifest.spec.instances == 2 &&
      database.manifest.spec.affinity.podAntiAffinityType == "required" &&
      database.manifest.spec.primaryUpdateMethod == "switchover" &&
      one(database.manifest.spec.plugins).isWALArchiver
    ])
    error_message = "Each database must keep a primary and a replica on separate nodes, switch over on updates, and archive WAL."
  }

  assert {
    condition = alltrue([for service, catalog in kubernetes_manifest.database_image :
      one(catalog.manifest.spec.images).image == data.terraform_remote_state.foundation.outputs.cluster.database_images[service] &&
      kubernetes_manifest.database_backups[service].manifest.spec.configuration.destinationPath == "gs://${data.terraform_remote_state.bootstrap.outputs.barman_buckets[service]}/"
    ])
    error_message = "Each database must run its service's released image and back up to its own bucket."
  }

  assert {
    condition = alltrue([for service, database in kubernetes_manifest.database :
      contains(database.manifest.spec.postgresql.shared_preload_libraries, "pg_cron") == contains(var.databases[service].extensions, "pg_cron")
    ])
    error_message = "Only a database that uses pg_cron preloads it."
  }
}
