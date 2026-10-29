# Plans the committed inputs against mocked providers and foundation's mocked outputs.
mock_provider "google" {}
mock_provider "kubernetes" {}
mock_provider "helm" {}

# Tests cannot import.
variables {
  adopted_databases = []
}

override_data {
  target = data.google_project.workload
  values = {
    number = "968960642520"
  }
}

override_data {
  target = data.terraform_remote_state.foundation
  values = {
    outputs = {
      region              = "europe-west1"
      workload_project_id = "a-novel-production-prod"
      cluster = {
        name              = "a-novel-production"
        location          = "europe-west9-a"
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
    condition = (
      !strcontains(join("\n", helm_release.external_secrets.values), "quay.io/") &&
      !strcontains(join("\n", helm_release.external_secrets.values), "ghcr.io/")
    )
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
      one(database.manifest.spec.plugins).isWALArchiver &&
      contains(database.computed_fields, "spec.postgresql.parameters")
    ])
    error_message = "Each database must keep a primary and a replica on separate nodes, switch over on updates, archive WAL, and accept the operator's parameter defaults."
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
  assert {
    condition = alltrue([for key, grant in google_secret_manager_secret_iam_member.secrets :
      endswith(grant.member, "/subject/ns/${split("/", key)[0]}/sa/secrets") &&
      grant.secret_id == "production-${split("/", key)[0]}-${split("/", key)[1]}" &&
      grant.role == "roles/secretmanager.secretAccessor"
    ])
    error_message = "Each namespace's identity must read only its own service's secrets."
  }

  assert {
    condition = alltrue(flatten([for service, store in kubernetes_manifest.secret_store : [
      store.manifest.spec.provider.gcpsm.projectID == "a-novel-management-prod",
      store.manifest.spec.provider.gcpsm.auth.workloadIdentity.serviceAccountRef.name == "secrets",
      [for item in kubernetes_manifest.secrets[service].manifest.spec.data :
        startswith(item.remoteRef.key, "production-${service}-") && can(regex("^[1-9][0-9]*$", item.remoteRef.version))
      ],
    ]]))
    error_message = "Each store must read management's secrets as its namespace's identity, only its service's, each at a pinned version."
  }
}

run "runs_json_keys_from_its_release" {
  command = plan

  variables {
    custom_resources = true
  }

  assert {
    condition = (
      toset([for copy in output.image_copies : copy.target]) == toset([for key, image in local.release_images : "${image.repository}/${image.path}:${image.tag}"]) &&
      alltrue([for copy in output.image_copies : startswith(copy.source, "ghcr.io/a-novel/service-json-keys/") && startswith(copy.target, "europe-west1-docker.pkg.dev/a-novel-production-prod/agora-json-keys-private-production/")]) &&
      alltrue([for image in values(local.release_image) : can(regex("^europe-west1-docker\\.pkg\\.dev/a-novel-production-prod/agora-json-keys-private-production/.+@sha256:[a-f0-9]{64}$", image))])
    )
    error_message = "JSON Keys must run its pinned release from its private repository, which this root's deploy copies it to."
  }

  assert {
    condition = (
      endswith(kubernetes_job_v1.json_keys_migrations[0].metadata[0].name, substr(trimprefix(local.release_images["json-keys/migrations"].digest, "sha256:"), 0, 12)) &&
      kubernetes_job_v1.json_keys_migrations[0].wait_for_completion &&
      one(one(kubernetes_job_v1.json_keys_migrations[0].spec[0].template[0].spec[0].container).security_context).run_as_non_root &&
      kubernetes_job_v1.json_keys_migrations[0].spec[0].backoff_limit == 0
    )
    error_message = "Each migrations image must run once, to completion, before the server rolls."
  }

  assert {
    condition = (
      length([for name in keys(local.json_keys_env) : name if startswith(name, "SENTRY_")]) == 0 &&
      local.json_keys_env.OTEL == "false" &&
      local.json_keys_env.SERVICE_TOKEN_ISSUER == "https://container.googleapis.com/v1/projects/a-novel-production-prod/locations/europe-west9-a/clusters/a-novel-production" &&
      local.json_keys_env.POSTGRES_HOST == "database-rw"
    )
    error_message = "JSON Keys must report nothing to Sentry, verify this cluster's service tokens, and use its CloudNativePG database."
  }

  assert {
    condition = (
      length(one(kubernetes_network_policy_v1.json_keys_grpc.spec).ingress) == 1 &&
      toset([for peer in one(one(kubernetes_network_policy_v1.json_keys_grpc.spec).ingress).from : one(peer.pod_selector).match_labels["app.kubernetes.io/name"]]) == toset(["rest", "smoke"]) &&
      one(one(one(kubernetes_network_policy_v1.json_keys_grpc.spec).ingress).ports).port == "8080"
    )
    error_message = "Only Authentication's API and the smoke check may call JSON Keys."
  }
}
