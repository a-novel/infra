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
      studio_edge = {
        host            = "studio.storyverse.fr"
        address_name    = "studio"
        ssl_policy      = "studio"
        certificate_map = "studio"
      }
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
    condition = (
      kubernetes_manifest.database_ca[0].manifest.spec.isCA &&
      kubernetes_manifest.database_ca[0].manifest.spec.privateKey.rotationPolicy == "Never" &&
      kubernetes_manifest.database_issuer[0].manifest.spec.ca.secretName == kubernetes_manifest.database_ca[0].manifest.spec.secretName &&
      alltrue([for service, certificate in kubernetes_manifest.database_server_certificate :
        certificate.manifest.spec.issuerRef.name == kubernetes_manifest.database_issuer[0].manifest.metadata.name &&
        certificate.manifest.spec.dnsNames == ["database-rw.${service}.svc"] &&
        certificate.manifest.spec.secretTemplate.labels["cnpg.io/reload"] == "" &&
        kubernetes_manifest.database[service].manifest.spec.certificates.serverTLSSecret == certificate.manifest.spec.secretName &&
        kubernetes_manifest.database[service].manifest.spec.certificates.serverCASecret == certificate.manifest.spec.secretName
      ])
    )
    error_message = "Each database must serve, and reload, a certificate for its own namespace's name from a CA that keeps its key."
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

run "runs_each_release_from_its_private_repository" {
  command = plan

  variables {
    custom_resources = true
  }

  assert {
    condition = (
      toset([for copy in output.image_copies : copy.target]) == toset([for key, image in local.release_images : "${image.repository}/${image.path}:${image.tag}"]) &&
      alltrue([for key, image in local.release_images :
        can(regex("^ghcr\\.io/a-novel/(service|platform)-${split("/", key)[0]}[/:]", image.source)) &&
        image.repository == "europe-west1-docker.pkg.dev/a-novel-production-prod/agora-${split("/", key)[0]}-private-production" &&
        can(regex("@sha256:[a-f0-9]{64}$", local.release_image[key]))
      ])
    )
    error_message = "Each service must run its pinned release from its own private repository, which this root's deploy copies it to."
  }

  assert {
    condition = (
      toset(keys(kubernetes_job_v1.migrations)) == toset(["authentication", "genai", "json-keys"]) &&
      alltrue([for service, job in kubernetes_job_v1.migrations :
        endswith(job.metadata[0].name, substr(trimprefix(local.release_images["${service}/migrations"].digest, "sha256:"), 0, 12)) &&
        job.wait_for_completion &&
        job.spec[0].backoff_limit == 0 &&
        !job.spec[0].template[0].spec[0].enable_service_links &&
        one(one(job.spec[0].template[0].spec[0].container).security_context).run_as_non_root
      ])
    )
    error_message = "Each service's migrations image must run once, to completion, before its server rolls."
  }

  assert {
    condition = alltrue([for service, job in kubernetes_job_v1.migrations :
      one(one(job.spec[0].template[0].spec[0].volume).secret).secret_name == kubernetes_manifest.database_server_certificate[service].manifest.spec.secretName &&
      [for item in one(one(job.spec[0].template[0].spec[0].volume).secret).items : item.key] == ["ca.crt"] &&
      one([for env in one(job.spec[0].template[0].spec[0].container).env : env.value if env.name == "SSL_CERT_DIR"]) == "/etc/ssl/certs:${one(one(job.spec[0].template[0].spec[0].container).volume_mount).mount_path}" &&
      one([for env in one(job.spec[0].template[0].spec[0].container).env : env.value if env.name == "POSTGRES_HOST"]) == one(kubernetes_manifest.database_server_certificate[service].manifest.spec.dnsNames)
    ])
    error_message = "The migrations must reach their own database by its certificate's name, trusting only its CA certificate beside the system roots."
  }
}

run "schedules_the_jobs_cloud_scheduler_runs" {
  command = plan

  variables {
    custom_resources = true
  }

  assert {
    condition = (
      toset(keys(kubernetes_cron_job_v1.scheduled)) == toset(["refresh-token-purge", "rotate-keys"]) &&
      kubernetes_cron_job_v1.scheduled["rotate-keys"].spec[0].schedule == "10 * * * *" &&
      kubernetes_cron_job_v1.scheduled["refresh-token-purge"].spec[0].schedule == "40 3 * * *" &&
      alltrue([for job in kubernetes_cron_job_v1.scheduled :
        job.spec[0].timezone == "Etc/UTC" &&
        job.spec[0].concurrency_policy == "Forbid" &&
        job.spec[0].job_template[0].spec[0].backoff_limit == 0
      ])
    )
    error_message = "Key rotation must run hourly at :10 and the refresh token purge daily at 03:40 UTC, one run at a time, never retried."
  }

  assert {
    condition = (
      kubernetes_cron_job_v1.scheduled["rotate-keys"].metadata[0].namespace == "json-keys" &&
      one(kubernetes_cron_job_v1.scheduled["rotate-keys"].spec[0].job_template[0].spec[0].template[0].spec[0].container).image == local.release_image["json-keys/rotatekeys"] &&
      one([for env in one(kubernetes_cron_job_v1.scheduled["rotate-keys"].spec[0].job_template[0].spec[0].template[0].spec[0].container).env : "${one(one(env.value_from).secret_key_ref).name}/${one(one(env.value_from).secret_key_ref).key}" if env.name == "APP_MASTER_KEY"]) == "secrets/APP_MASTER_KEY" &&
      kubernetes_cron_job_v1.scheduled["refresh-token-purge"].metadata[0].namespace == "authentication" &&
      one(kubernetes_cron_job_v1.scheduled["refresh-token-purge"].spec[0].job_template[0].spec[0].template[0].spec[0].container).image == local.release_image["authentication/maintenance"] &&
      one(kubernetes_cron_job_v1.scheduled["refresh-token-purge"].spec[0].job_template[0].spec[0].template[0].spec[0].container).args == tolist(["refresh-token-purge"])
    )
    error_message = "Key rotation must run JSON Keys' rotatekeys image with its master key, and the purge Authentication's maintenance image."
  }

  assert {
    condition = alltrue([for name, job in kubernetes_cron_job_v1.scheduled :
      job.spec[0].job_template[0].spec[0].template[0].metadata[0].labels["a-novel.io/database"] == "client" &&
      one(one(job.spec[0].job_template[0].spec[0].template[0].spec[0].volume).secret).secret_name == kubernetes_manifest.database_server_certificate[local.scheduled_jobs[name].service].manifest.spec.secretName &&
      one([for env in one(job.spec[0].job_template[0].spec[0].template[0].spec[0].container).env : env.value if env.name == "POSTGRES_HOST"]) == one(kubernetes_manifest.database_server_certificate[local.scheduled_jobs[name].service].manifest.spec.dnsNames) &&
      one([for env in one(job.spec[0].job_template[0].spec[0].template[0].spec[0].container).env : env.value if env.name == "SSL_CERT_DIR"]) == "/etc/ssl/certs:/etc/database-ca" &&
      one([for env in one(job.spec[0].job_template[0].spec[0].template[0].spec[0].container).env : env.value if env.name == "OTEL"]) == "false"
    ])
    error_message = "Each scheduled job must reach its own database as a client, by its certificate's name, trusting its CA, and export no telemetry until Alloy runs."
  }
}

run "runs_json_keys" {
  command = plan

  variables {
    custom_resources = true
  }

  assert {
    condition = (
      length([for name in keys(local.json_keys_env) : name if startswith(name, "SENTRY_")]) == 0 &&
      local.json_keys_env.OTEL == "false" &&
      local.json_keys_env.SERVICE_TOKEN_ISSUER == "https://container.googleapis.com/v1/projects/a-novel-production-prod/locations/europe-west9-a/clusters/a-novel-production" &&
      local.json_keys_env.POSTGRES_HOST == one(kubernetes_manifest.database_server_certificate["json-keys"].manifest.spec.dnsNames)
    )
    error_message = "JSON Keys must report nothing to Sentry, verify this cluster's service tokens, and use its CloudNativePG database by its certificate's name."
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

run "runs_authentication" {
  command = plan

  variables {
    custom_resources = true
  }

  assert {
    condition = (
      length([for name in keys(local.authentication_env) : name if startswith(name, "SENTRY_")]) == 0 &&
      local.authentication_env.OTEL == "false" &&
      local.authentication_env.POSTGRES_HOST == one(kubernetes_manifest.database_server_certificate["authentication"].manifest.spec.dnsNames) &&
      local.authentication_env.SMTP_ADDR == "smtp-relay.gmail.com:587" &&
      local.authentication_env.PLATFORM_AUTH_URL == "https://studio.storyverse.fr"
    )
    error_message = "Authentication must report nothing to Sentry, use its CloudNativePG database by its certificate's name, and send its root's mail with links to Studio."
  }

  # A release without service tokens sends Google ID tokens when GCLOUD_PROJECT_ID is set, which
  # JSON Keys on the cluster cannot take.
  assert {
    condition = (
      !contains(keys(local.authentication_env), "GCLOUD_PROJECT_ID") &&
      startswith(local.authentication_env.SERVICE_JSON_KEYS_HOST, "${module.json_keys_grpc[0].pod_labels["app.kubernetes.io/name"]}.json-keys.") &&
      contains(split(",", local.json_keys_env.SERVICE_TOKEN_CALLERS), module.authentication_rest[0].service_account) &&
      one(one(one(kubernetes_network_policy_v1.authentication_rest.spec).egress[0].to).pod_selector).match_labels["app.kubernetes.io/name"] == module.json_keys_grpc[0].pod_labels["app.kubernetes.io/name"] &&
      one(one(kubernetes_network_policy_v1.authentication_rest.spec).egress[0].ports).port == local.json_keys_env.GRPC_PORT
    )
    error_message = "Authentication must call JSON Keys' server directly, as a caller JSON Keys admits."
  }

  assert {
    condition = (
      length(one(kubernetes_network_policy_v1.authentication_rest.spec).ingress) == 1 &&
      toset([for peer in one(one(kubernetes_network_policy_v1.authentication_rest.spec).ingress).from : one(peer.pod_selector).match_labels["app.kubernetes.io/name"]]) == toset(["web", "smoke"]) &&
      toset(split(",", local.authentication_env.SERVICE_TOKEN_CALLERS)) == toset(["system:serviceaccount:studio:web", "system:serviceaccount:authentication:smoke"]) &&
      one(one(one(kubernetes_network_policy_v1.authentication_rest.spec).ingress).ports).port == local.authentication_env.REST_PORT
    )
    error_message = "Only Studio and the smoke check may call Authentication, whose visitor IP header trusts Studio."
  }
}

run "runs_genai" {
  command = plan

  variables {
    custom_resources = true
  }

  assert {
    condition = alltrue([for env in [local.genai_grpc_env, local.genai_sweep_env] :
      length([for name in keys(env) : name if startswith(name, "SENTRY_")]) == 0 &&
      env.OTEL == "false" &&
      env.POSTGRES_HOST == one(kubernetes_manifest.database_server_certificate["genai"].manifest.spec.dnsNames)
    ])
    error_message = "GenAI's server and sweep must report nothing to Sentry, and use their CloudNativePG database by its certificate's name."
  }

  assert {
    condition = (
      local.genai_secret_env.OPENAI_API_KEY.secret == "secrets" &&
      contains(keys(var.secrets["genai"]), local.genai_secret_env.OPENAI_API_KEY.key) &&
      local.genai_sweep_env.SWEEP_TICKER == "true" &&
      local.genai_grpc_env.GRPC_MAX_CONCURRENT_CALLS == "20"
    )
    error_message = "Both read OpenAI's key from the namespace's synced secrets, the sweep runs itself, and the server refuses calls beyond the 20 its memory is sized for."
  }

  assert {
    condition = (
      local.genai_grpc_env.SERVICE_TOKEN_CALLERS == "system:serviceaccount:genai:smoke" &&
      length(one(kubernetes_network_policy_v1.genai_grpc.spec).ingress) == 1 &&
      [for peer in one(one(kubernetes_network_policy_v1.genai_grpc.spec).ingress).from : one(peer.pod_selector).match_labels["app.kubernetes.io/name"]] == ["smoke"] &&
      length(one(one(one(kubernetes_network_policy_v1.genai_grpc.spec).ingress).from).namespace_selector) == 0
    )
    error_message = "Only GenAI's own smoke check may call its server."
  }
}

run "runs_studio" {
  command = plan

  variables {
    custom_resources = true
  }

  assert {
    condition = (
      length([for name in keys(local.studio_env) : name if startswith(name, "SENTRY_") || startswith(name, "PUBLIC_SENTRY_")]) == 0 &&
      local.studio_env.OTEL == "false" &&
      local.studio_env.ORIGIN == "https://studio.storyverse.fr" &&
      local.studio_env.ADDRESS_HEADER == "X-Forwarded-For" &&
      local.studio_env.XFF_DEPTH == "2"
    )
    error_message = "Studio must report nothing to Sentry, check form posts against its own host, and take the visitor's address the load balancer appends."
  }

  # A release without service tokens sends Google ID tokens when AUTHENTICATION_SERVICE_AUDIENCE is
  # set, which Authentication on the cluster cannot take.
  assert {
    condition = (
      !contains(keys(local.studio_env), "AUTHENTICATION_SERVICE_AUDIENCE") &&
      local.studio_env.AUTHENTICATION_SERVICE_URL == "http://${module.authentication_rest[0].pod_labels["app.kubernetes.io/name"]}.authentication.svc:${local.authentication_env.REST_PORT}" &&
      contains(split(",", local.authentication_env.SERVICE_TOKEN_CALLERS), module.studio_web.service_account) &&
      one(one(one(kubernetes_network_policy_v1.studio_web.spec).egress).to).pod_selector[0].match_labels["app.kubernetes.io/name"] == module.authentication_rest[0].pod_labels["app.kubernetes.io/name"] &&
      one(one(one(kubernetes_network_policy_v1.studio_web.spec).egress).ports).port == local.authentication_env.REST_PORT &&
      contains([for peer in one(one(kubernetes_network_policy_v1.authentication_rest.spec).ingress).from : one(peer.pod_selector).match_labels["app.kubernetes.io/name"]], module.studio_web.pod_labels["app.kubernetes.io/name"])
    )
    error_message = "Studio must call Authentication's API directly, as a caller Authentication admits."
  }
}

run "serves_studio_through_the_gateway" {
  command = plan

  variables {
    custom_resources = true
  }

  assert {
    condition = (
      kubernetes_manifest.studio_gateway[0].manifest.spec.gatewayClassName == "gke-l7-global-external-managed" &&
      kubernetes_manifest.studio_gateway[0].manifest.spec.addresses == [{ type = "NamedAddress", value = "studio" }] &&
      kubernetes_manifest.studio_gateway[0].manifest.metadata.annotations["networking.gke.io/certmap"] == "studio" &&
      kubernetes_manifest.studio_gateway_policy[0].manifest.spec.default.sslPolicy == "studio" &&
      alltrue([for listener in kubernetes_manifest.studio_gateway[0].manifest.spec.listeners : listener.hostname == local.studio_host])
    )
    error_message = "The Gateway must answer only for Studio's host, on foundation's address, certificate map and TLS policy."
  }

  assert {
    condition = (
      kubernetes_manifest.studio_route[0].manifest.spec.hostnames == [local.studio_host] &&
      one(kubernetes_manifest.studio_route[0].manifest.spec.parentRefs).sectionName == "https" &&
      one(one(kubernetes_manifest.studio_route[0].manifest.spec.rules).backendRefs) == module.studio_web.service &&
      one(kubernetes_manifest.studio_redirect[0].manifest.spec.parentRefs).sectionName == "http" &&
      one(one(kubernetes_manifest.studio_redirect[0].manifest.spec.rules).filters).requestRedirect.scheme == "https" &&
      length(keys(one(kubernetes_manifest.studio_redirect[0].manifest.spec.rules))) == 1
    )
    error_message = "HTTPS must reach Studio's Service, and plain HTTP must only redirect to HTTPS."
  }

  assert {
    condition = (
      kubernetes_manifest.studio_health_check[0].manifest.spec.targetRef.name == module.studio_web.service.name &&
      kubernetes_manifest.studio_health_check[0].manifest.spec.default.config.httpHealthCheck.requestPath == "/ping" &&
      kubernetes_manifest.studio_health_check[0].manifest.spec.default.config.httpHealthCheck.port == module.studio_web.service.port &&
      local.studio_env.ORIGIN == "https://${local.studio_host}" &&
      local.authentication_env.PLATFORM_AUTH_URL == local.studio_env.ORIGIN
    )
    error_message = "The load balancer must check Studio on its probes' path, and Studio and Authentication's links must name the Gateway's host."
  }

  assert {
    condition = (
      length(one(kubernetes_network_policy_v1.studio_web.spec).ingress) == 1 &&
      toset([for peer in one(one(kubernetes_network_policy_v1.studio_web.spec).ingress).from : one(peer.ip_block).cidr]) == toset(["35.191.0.0/16", "130.211.0.0/22"]) &&
      alltrue([for peer in one(one(kubernetes_network_policy_v1.studio_web.spec).ingress).from : length(peer.pod_selector) == 0 && length(peer.namespace_selector) == 0]) &&
      one(one(one(kubernetes_network_policy_v1.studio_web.spec).ingress).ports).port == tostring(module.studio_web.service.port)
    )
    error_message = "Only Google's load balancer may reach Studio, on its port."
  }
}
