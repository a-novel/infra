# Plans the committed inputs against mocked providers and foundation's mocked outputs.
mock_provider "google" {}
mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "time" {}

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
      platform_edges = {
        account = {
          host            = "account.storyverse.fr"
          address_name    = "account"
          ssl_policy      = "account"
          certificate_map = "account"
        }
        studio = {
          host            = "studio.storyverse.fr"
          address_name    = "studio"
          ssl_policy      = "studio"
          certificate_map = "studio"
        }
      }
      cluster = {
        name              = "a-novel-production"
        location          = "europe-west9-a"
        dns_endpoint      = "gke-mock.europe-west1-d.gke.goog"
        node_range        = "10.30.0.0/24"
        google_api_ranges = ["199.36.153.4/30", "34.126.0.0/18"]
        image_registries = {
          "docker.io"       = "europe-west1-docker.pkg.dev/a-novel-production-prod/a-novel-docker-io"
          "ghcr.io"         = "europe-west1-docker.pkg.dev/a-novel-production-prod/a-novel-ghcr-io"
          "quay.io"         = "europe-west1-docker.pkg.dev/a-novel-production-prod/a-novel-quay-io"
          "registry.k8s.io" = "europe-west1-docker.pkg.dev/a-novel-production-prod/a-novel-registry-k8s-io"
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
    condition = alltrue([for registry in ["docker.io/", "ghcr.io/", "quay.io/", "registry.k8s.io/"] :
      !strcontains(join("\n", concat(helm_release.external_secrets.values, helm_release.alloy.values, helm_release.counter_store[0].values)), registry)
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

run "sends_every_signal_to_grafana_through_alloy" {
  command = plan

  variables {
    custom_resources = true
  }

  assert {
    condition = (
      local.alloy_values.global.scrapeInterval == "60s" &&
      local.alloy_values.clusterEvents.enabled &&
      alltrue([for feature in ["nodeLogs", "podLogsObjects", "podLogsViaKubernetesApi", "podLogsViaLoki", "podLogsViaOpenTelemetry"] : !try(local.alloy_values[feature].enabled, false)]) &&
      !try(local.alloy_values.hostMetrics.enabled, false) &&
      !try(local.alloy_values.telemetryServices["node-exporter"].deploy, false) &&
      contains(local.alloy_values.annotationAutodiscovery.metricsTuning.excludeMetrics, "cnpg_pg_settings_setting")
    )
    error_message = "Alloy must scrape every 60 seconds, send the cluster's events, collect no log the services already send, run no Node Exporter, and drop CloudNativePG's settings."
  }

  assert {
    condition = alltrue([for scope in [
      local.alloy_values.clusterEvents.namespaces,
      local.alloy_values.clusterMetrics.cadvisor.metricsTuning.includeNamespaces,
      split(",", local.alloy_values.telemetryServices["kube-state-metrics"].namespaces),
      local.alloy_values.annotationAutodiscovery.namespaces,
    ] : length(scope) > 0 && length(setsubtract(scope, setunion(var.namespaces, local.addon_namespaces))) == 0])
    error_message = "Alloy must read the events, containers, objects and pods of this root's namespaces alone."
  }

  # The span metrics come from the server spans and the roots alone, under one series per service
  # whatever its pods, and the chart's own span metrics stay off. Each span is classified before it
  # reaches Grafana or the span metrics, so both read the same outcome.
  assert {
    condition = (
      local.alloy_values.applicationObservability.traces.transforms.span == local.outcome_statements &&
      strcontains(local.alloy_values.destinations.span-metrics.config, "span = [`kind != SPAN_KIND_SERVER and not IsRootSpan()`]") &&
      toset(flatten(regexall("name = \"([^\"]+)\"", local.alloy_values.destinations.span-metrics.config))) == toset(["a_novel.outcome", "http.response.status_code", "rpc.response.status_code", "error.type", "a_novel.workload"]) &&
      strcontains(local.alloy_values.destinations.span-metrics.config, "exponential {") &&
      strcontains(local.alloy_values.destinations.span-metrics.config, "exclude_dimensions              = [\"span.kind\"]") &&
      strcontains(local.alloy_values.destinations.span-metrics.config, "resource_metrics_key_attributes = [\"service.name\"]") &&
      strcontains(local.alloy_values.destinations.span-metrics.config, "statements = [`keep_keys(attributes, [\"service.name\"])`]") &&
      strcontains(local.alloy_values.destinations.span-metrics.config, "metrics = [otelcol.processor.attributes.grafana_cloud.input]") &&
      contains(local.alloy_values.applicationObservability.destinations, "span-metrics") &&
      !try(local.alloy_values.applicationObservability.connectors.spanMetrics.enabled, false) &&
      local.alloy_values.collectors.alloy.presets == ["singleton"]
    )
    error_message = "Span metrics must count the classified server and root spans by service, span name, status, outcome, response code, error type and workload, in a native histogram, on a single collector, with no pod or instance label."
  }

  # Alloy reads no Secret, and the operator manages its own namespace alone.
  assert {
    condition = (
      !local.alloy_values.collectors.alloy.rbac.create &&
      alltrue([for rule in kubernetes_cluster_role_v1.alloy.rule : length(setintersection(rule.resources, ["configmaps", "secrets"])) == 0 && length(setsubtract(rule.verbs, ["get", "list", "watch"])) == 0]) &&
      local.alloy_values.alloy-operator.ownNamespaceOnly &&
      !local.alloy_values.alloy-operator.rbac.createClusterRoles &&
      local.alloy_values.destinations.grafana-cloud.secret.embed &&
      one(local.alloy_values.collectors.alloy.alloy.extraEnv).valueFrom.secretKeyRef.name == kubernetes_manifest.secrets["alloy"].manifest.spec.target.name &&
      contains(keys(var.secrets["alloy"]), one(local.alloy_values.collectors.alloy.alloy.extraEnv).valueFrom.secretKeyRef.key) &&
      length(setintersection(local.alloy_values.telemetryServices["kube-state-metrics"].collectors, ["configmaps", "secrets"])) == 0
    )
    error_message = "Alloy must read only cluster state, take its push token from its namespace's synced secrets, and leave the operator its own namespace alone."
  }

  assert {
    condition = (
      local.alloy_values.destinations.grafana-cloud.url == "https://${kubernetes_manifest.internet_egress["grafana-otlp"].manifest.spec.egress[0].matches[0].name}/otlp" &&
      kubernetes_manifest.internet_egress["grafana-otlp"].manifest.metadata.namespace == helm_release.alloy.namespace &&
      toset(kubernetes_manifest.internet_egress["grafana-otlp"].manifest.spec.podSelector.matchExpressions[0].values) == toset(keys(local.alloy_values.collectors))
    )
    error_message = "Only Alloy's collector may reach Grafana, at the gateway it sends to."
  }

  # Every service's pods reach the receiver, and nothing else reaches Alloy.
  assert {
    condition = (
      length(one(kubernetes_network_policy_v1.alloy.spec).ingress) == 1 &&
      toset(one(one(one(one(kubernetes_network_policy_v1.alloy.spec).ingress).from).namespace_selector).match_expressions[0].values) == toset(var.namespaces) &&
      [for port in one(one(kubernetes_network_policy_v1.alloy.spec).ingress).ports : port.port] == ["4318"] &&
      one(kubernetes_network_policy_v1.alloy.spec).pod_selector[0].match_labels["app.kubernetes.io/name"] == one(keys(local.alloy_values.collectors)) &&
      toset(keys(kubernetes_network_policy_v1.telemetry)) == toset(var.namespaces) &&
      alltrue([for policy in kubernetes_network_policy_v1.telemetry :
        one(one(one(policy.spec).egress).to).pod_selector[0].match_labels == one(kubernetes_network_policy_v1.alloy.spec).pod_selector[0].match_labels &&
        [for port in one(one(policy.spec).egress).ports : port.port] == ["4318"]
      ])
    )
    error_message = "Alloy's receiver must admit every service's pods, and only them, on OTLP/HTTP alone."
  }

  assert {
    condition = alltrue([for service, policy in kubernetes_network_policy_v1.database :
      length([for rule in one(policy.spec).ingress : rule if anytrue([for peer in rule.from : try(peer.namespace_selector[0].match_labels["kubernetes.io/metadata.name"], "") == "alloy"])]) == 1 &&
      one([for rule in one(policy.spec).ingress : [for port in rule.ports : port.port] if anytrue([for peer in rule.from : try(peer.namespace_selector[0].match_labels["kubernetes.io/metadata.name"], "") == "alloy"])]) == ["9187"] &&
      kubernetes_manifest.database[service].manifest.spec.inheritedMetadata.annotations["k8s.grafana.com/scrape"] == "true"
    ])
    error_message = "Alloy must reach each database's metrics port alone."
  }

  # Each workload exports to the receiver under its repository's name, as on Cloud Run.
  assert {
    condition = alltrue([for workload in concat([
      { env = local.json_keys_env, kind = "api" },
      { env = local.authentication_env, kind = "api" },
      { env = local.genai_grpc_env, kind = "api" },
      { env = local.genai_sweep_env, kind = "job" },
      { env = { for env in one(kubernetes_cron_job_v1.scheduled["rotate-keys"].spec[0].job_template[0].spec[0].template[0].spec[0].container).env : env.name => env.value }, kind = "job" },
      { env = { for env in one(kubernetes_cron_job_v1.scheduled["refresh-token-purge"].spec[0].job_template[0].spec[0].template[0].spec[0].container).env : env.name => env.value }, kind = "job" },
      ], [for env in values(local.platform_env) : { env = env, kind = "api" }]) :
      workload.env.OTEL == "true" &&
      workload.env.OTEL_EXPORTER_OTLP_ENDPOINT == "http://${one(keys(local.alloy_values.collectors))}.${helm_release.alloy.namespace}.svc:${local.alloy_values.applicationObservability.receivers.otlp.http.port}" &&
      can(regex("^(service|platform)-[a-z-]+$", workload.env.OTEL_SERVICE_NAME)) &&
      workload.env.OTEL_RESOURCE_ATTRIBUTES == "a_novel.workload=${workload.kind}"
    ])
    error_message = "Every server, the sweep, the jobs and the platforms must export to Alloy's receiver, named after their repository, as an api or a job."
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
      one(catalog.manifest.spec.images).image == local.release_image["${service}/database"] &&
      kubernetes_manifest.database_backups[service].manifest.spec.configuration.destinationPath == "gs://${data.terraform_remote_state.bootstrap.outputs.barman_buckets[service]}/"
    ])
    error_message = "Each database must run its service's released image and back up to its own bucket."
  }

  # The webhook puts CloudNativePG's own queries first when the list lacks them, which every apply
  # would then undo.
  assert {
    condition = alltrue([for service, database in kubernetes_manifest.database :
      contains(keys(kubernetes_config_map_v1.database_queries), service)
      ? database.manifest.spec.monitoring.customQueriesConfigMap == [{ name = "cnpg-default-monitoring", key = "queries" }, { name = "database-queries", key = "queries.yaml" }]
      : !can(database.manifest.spec.monitoring)
    ]) && toset(keys(kubernetes_config_map_v1.database_queries)) == toset(keys(var.databases))
    error_message = "Each database must export its own numbers, listed after CloudNativePG's queries."
  }

  assert {
    condition = toset(keys(kubernetes_job_v1.database_grants)) == toset(keys(kubernetes_config_map_v1.database_queries)) && alltrue([for service, job in kubernetes_job_v1.database_grants :
      job.wait_for_completion &&
      one(job.spec[0].template[0].spec[0].container).command == tolist(["psql", "--no-psqlrc", "--command", file("queries/${service}.sql")]) &&
      alltrue([for statement in regexall("GRANT[^;]*;", file("queries/${service}.sql")) : can(regex("^GRANT SELECT \\([a-z_, ]+\\) ON [a-z_]+ TO cnpg_metrics_exporter;$", statement))]) &&
      one([for env in one(job.spec[0].template[0].spec[0].container).env : env.value if env.name == "PGSSLMODE"]) == "verify-full" &&
      one([for env in one(job.spec[0].template[0].spec[0].container).env : env.value if env.name == "PGHOST"]) == one(kubernetes_manifest.database_server_certificate[service].manifest.spec.dnsNames)
    ])
    error_message = "Each database must grant CloudNativePG's exporter only the columns its queries read, over verified TLS."
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

  assert {
    condition = alltrue([for database in kubernetes_manifest.database :
      !can(database.manifest.spec.bootstrap.initdb.import) && !can(database.manifest.spec.externalClusters)
    ])
    error_message = "The database hosts are gone, so no database imports from one or names one."
  }

  assert {
    condition = alltrue([for workload in [module.json_keys_grpc[0], module.authentication_rest[0], module.genai_grpc[0], module.genai_sweep[0]] :
      workload.pod_annotations["a-novel.io/database-lineage"] == var.backup_server_name
    ])
    error_message = "Every database client's pods must roll with a new lineage, once its database serves."
  }

  assert {
    condition = alltrue([for service, database in kubernetes_manifest.database : (
      database.manifest.spec.certificates.replicationTLSSecret == kubernetes_manifest.database_replication_certificate[service].manifest.spec.secretName &&
      database.manifest.spec.certificates.clientCASecret == kubernetes_manifest.database_replication_certificate[service].manifest.spec.secretName &&
      kubernetes_manifest.database_replication_certificate[service].manifest.spec.commonName == "streaming-replica.${service}" &&
      kubernetes_manifest.database_replication_certificate[service].manifest.spec.usages == ["client auth"] &&
      kubernetes_manifest.database_replication_certificate[service].manifest.spec.issuerRef.name == kubernetes_manifest.database_issuer[0].manifest.metadata.name &&
      database.manifest.spec.postgresql.pg_ident == ["cnpg_streaming_replica streaming-replica.${service} streaming_replica"]
    )])
    error_message = "Each database's replica must authenticate with our CA's certificate, which only its own database accepts."
  }

  assert {
    condition     = time_sleep.database_lineage.create_duration == "4m" && time_sleep.database_lineage.triggers.lineage == var.backup_server_name
    error_message = "A new lineage must wait four minutes before its databases replace the old ones."
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
        image.repository == "europe-west9-docker.pkg.dev/a-novel-production-prod/a-novel-${split("/", key)[0]}" &&
        can(regex("@sha256:[a-f0-9]{64}$", local.release_image[key]))
      ])
    )
    error_message = "Each service must run its pinned release from its own private repository, which this root's deploy copies it to."
  }

  assert {
    condition = (
      toset(keys(kubernetes_job_v1.migrations)) == toset(["authentication", "genai", "json-keys"]) &&
      alltrue([for service, job in kubernetes_job_v1.migrations :
        startswith(job.metadata[0].name, "migrations-${substr(trimprefix(local.release_images["${service}/migrations"].digest, "sha256:"), 0, 12)}-") &&
        endswith(job.metadata[0].name, substr(sha256(var.backup_server_name), 0, 8)) &&
        job.wait_for_completion &&
        job.spec[0].backoff_limit == 0 &&
        !job.spec[0].template[0].spec[0].enable_service_links &&
        one(one(job.spec[0].template[0].spec[0].container).security_context).run_as_non_root
      ])
    )
    error_message = "Each service's migrations must run once per image and per database lineage, to completion, before its server rolls."
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
      toset([for name, job in kubernetes_cron_job_v1.scheduled : name if !job.spec[0].suspend]) == toset(["refresh-token-purge", "rotate-keys"]) &&
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
      one([for env in one(job.spec[0].job_template[0].spec[0].template[0].spec[0].container).env : env.value if env.name == "SSL_CERT_DIR"]) == "/etc/ssl/certs:/etc/database-ca"
    ])
    error_message = "Each scheduled job must reach its own database as a client, by its certificate's name, trusting its CA."
  }
}

run "lets_operators_read_the_services" {
  command = plan

  assert {
    condition = (
      toset(keys(kubernetes_role_binding_v1.operators)) == toset(var.namespaces) &&
      alltrue([for binding in kubernetes_role_binding_v1.operators :
        binding.role_ref[0].kind == "ClusterRole" &&
        binding.role_ref[0].name == "view" &&
        toset([for subject in binding.subject : "${lower(subject.kind)}:${subject.name}"]) == toset(local.operators)
      ])
    )
    error_message = "Foundation's database operators must read each service's namespace through the view role, which never reads Secrets, and nothing more."
  }
}

run "reaches_only_its_internet_hosts" {
  command = plan

  variables {
    custom_resources = true
  }

  assert {
    condition = (
      { for name, policy in kubernetes_manifest.internet_egress : name => "${policy.manifest.metadata.namespace}:${join(",", policy.manifest.spec.podSelector.matchExpressions[0].values)}:${policy.manifest.spec.egress[0].matches[0].name}:${policy.manifest.spec.egress[0].ports[0].port}" } == {
        openai             = "genai:grpc,sweep:api.openai.com:443"
        smtp-relay         = "authentication:maintenance,rest:smtp-relay.gmail.com:587"
        github-raw         = "studio:web:raw.githubusercontent.com:443"
        github-raw-account = "account:web:raw.githubusercontent.com:443"
        grafana-otlp       = "alloy:alloy:otlp-gateway-prod-eu-west-2.grafana.net:443"
      } &&
      alltrue([for policy in kubernetes_manifest.internet_egress : policy.manifest.kind == "FQDNNetworkPolicy" && length(policy.manifest.spec.egress) == 1])
    )
    error_message = "GenAI may reach only OpenAI, Authentication only the mail relay, the platforms only GitHub's raw host, and Alloy only Grafana's gateway, each on its own port."
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
      local.authentication_env.POSTGRES_HOST == one(kubernetes_manifest.database_server_certificate["authentication"].manifest.spec.dnsNames) &&
      local.authentication_env.SMTP_ADDR == "smtp-relay.gmail.com:587" &&
      local.authentication_env.PLATFORM_AUTH_URL == "https://account.storyverse.fr"
    )
    error_message = "Authentication must report nothing to Sentry, use its CloudNativePG database by its certificate's name, and send its root's mail with links to the account platform."
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
      toset(split(",", local.authentication_env.SERVICE_TOKEN_CALLERS)) == toset(["system:serviceaccount:account:web", "system:serviceaccount:studio:web", "system:serviceaccount:authentication:smoke"]) &&
      one(one(one(kubernetes_network_policy_v1.authentication_rest.spec).ingress).ports).port == local.authentication_env.REST_PORT
    )
    error_message = "Only the platforms and the smoke check may call Authentication, whose visitor IP header trusts the platforms."
  }
}

run "keeps_authentication_counters_in_a_locked_store" {
  command = plan

  variables {
    custom_resources = true
  }

  assert {
    condition = alltrue([for image in [local.counter_store_values.image, local.counter_store_values.metrics.exporter.image] :
      startswith(image.registry, "europe-west1-docker.pkg.dev/a-novel-production-prod/") && can(regex("^[^@]+@sha256:[a-f0-9]{64}$", image.tag))
    ])
    error_message = "Valkey and its exporter must pull through our Artifact Registry, pinned by digest."
  }

  assert {
    condition = (
      !try(local.counter_store_values.dataStorage.enabled, false) &&
      !try(local.counter_store_values.replica.enabled, false) &&
      length(setintersection(split("\n", local.counter_store_values.valkeyConfig), ["save \"\"", "appendonly no"])) == 2
    )
    error_message = "The counter store must keep nothing on disk: no volume, no replica, no snapshot and no append-only file."
  }

  # Each user's key and channel patterns, then its commands. The chart turns each user on but the
  # default one.
  assert {
    condition = (
      [for rule in split(" ", local.counter_store_values.auth.aclUsers.limiter.permissions) : rule if can(regex("^([~%&]|all(keys|channels)$)", rule))] == ["~httprate:*"] &&
      toset([for rule in split(" ", local.counter_store_values.auth.aclUsers.limiter.permissions) : rule if startswith(rule, "+")]) == toset(["+mget", "+incrby", "+expire", "+multi", "+exec", "+ping", "+client|setinfo"]) &&
      length([for rule in split(" ", local.counter_store_values.auth.aclUsers.exporter.permissions) : rule if can(regex("^([~%&]|all(keys|channels)$)", rule))]) == 0 &&
      toset([for rule in split(" ", local.counter_store_values.auth.aclUsers.exporter.permissions) : rule if startswith(rule, "+")]) == toset(["+info", "+slowlog|len", "+slowlog|get", "+commandlog|len", "+command|info"]) &&
      toset(split(" ", local.counter_store_values.auth.aclUsers.default.permissions)) == toset(["off", "resetpass"]) &&
      alltrue([for user in values(local.counter_store_values.auth.aclUsers) : !contains(split(" ", user.permissions), "nopass") && !contains(split(" ", user.permissions), "allcommands")])
    )
    error_message = "The limiter may run only httprate's commands on its own keys, the exporter only read statistics and no key, and the default user nothing."
  }

  # Every user's password comes from the generated Secret, and the exporter logs in as itself.
  assert {
    condition = (
      kubernetes_manifest.counter_store_users[0].manifest.spec.target.name == local.counter_store_values.auth.usersExistingSecret &&
      kubernetes_manifest.counter_store_users[0].manifest.spec.refreshPolicy == "CreatedOnce" &&
      toset(kubernetes_manifest.counter_store_passwords[0].manifest.spec.secretKeys) == toset([for name, user in local.counter_store_values.auth.aclUsers : try(user.passwordKey, name)]) &&
      contains(local.counter_store_values.metrics.exporter.args, "--redis.user=${local.counter_store_values.auth.aclUsers.default.passwordKey}")
    )
    error_message = "Each user's password must be generated once into the Secret the chart reads, and the exporter must log in as its own user."
  }

  assert {
    condition = (
      toset(one(kubernetes_network_policy_v1.counter_store.spec).policy_types) == toset(["Ingress", "Egress"]) &&
      length(one(kubernetes_network_policy_v1.counter_store.spec).egress) == 0 &&
      [for rule in one(kubernetes_network_policy_v1.counter_store.spec).ingress : [for port in rule.ports : port.port]] == [["6379"], ["9121"]] &&
      [for peer in one(kubernetes_network_policy_v1.counter_store.spec).ingress[0].from : one(peer.pod_selector).match_labels["app.kubernetes.io/name"]] == [module.authentication_rest[0].pod_labels["app.kubernetes.io/name"]] &&
      length(one(one(kubernetes_network_policy_v1.counter_store.spec).ingress[0].from).namespace_selector) == 0 &&
      [for peer in one(kubernetes_network_policy_v1.counter_store.spec).ingress[1].from : one(peer.namespace_selector).match_labels["kubernetes.io/metadata.name"]] == [helm_release.alloy.namespace] &&
      one(one(one(kubernetes_network_policy_v1.counter_store.spec).ingress[1].from).pod_selector).match_labels == one(kubernetes_network_policy_v1.alloy.spec).pod_selector[0].match_labels
    )
    error_message = "Only Authentication's API pods may reach Valkey, only Alloy its exporter, and the store's policy may open no egress."
  }

  assert {
    condition = (
      local.counter_store_values.podAnnotations["k8s.grafana.com/scrape"] == "true" &&
      contains(local.alloy_values.annotationAutodiscovery.namespaces, helm_release.counter_store[0].namespace) &&
      one([for rule in one(kubernetes_network_policy_v1.alloy.spec).egress : [for port in rule.ports : port.port] if anytrue([for peer in rule.to :
        try(one(peer.namespace_selector).match_labels["kubernetes.io/metadata.name"] == helm_release.counter_store[0].namespace && one(peer.pod_selector).match_labels == tomap(local.counter_store_pods), false)
      ])]) == ["9121"]
    )
    error_message = "Alloy must discover the counter store and reach its exporter's port alone."
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
    error_message = "Both read OpenAI's key from the namespace's synced secrets, the sweep checks generations on its own ticker, and the server refuses calls beyond the 20 its memory is sized for."
  }

  assert {
    condition = (
      local.genai_grpc_env.SERVICE_TOKEN_CALLERS == "system:serviceaccount:genai:smoke" &&
      [for rule in one(kubernetes_network_policy_v1.genai_grpc.spec).ingress : [for port in rule.ports : port.port]] == [[local.genai_grpc_env.GRPC_PORT], [local.genai_grpc_env.METRICS_PORT]] &&
      [for peer in one(kubernetes_network_policy_v1.genai_grpc.spec).ingress[0].from : one(peer.pod_selector).match_labels["app.kubernetes.io/name"]] == ["smoke"] &&
      length(one(one(kubernetes_network_policy_v1.genai_grpc.spec).ingress[0].from).namespace_selector) == 0
    )
    error_message = "Only GenAI's own smoke check may call its server."
  }

  # Each peer of the metrics rule names its source range or namespace, and one of them only.
  assert {
    condition = [for peer in one(kubernetes_network_policy_v1.genai_grpc.spec).ingress[1].from :
      concat([for block in peer.ip_block : block.cidr], [for selector in peer.namespace_selector : selector.match_labels["kubernetes.io/metadata.name"]])
    ] == [[local.cluster.node_range], ["kube-system"]]
    error_message = "Only the nodes and kube-system may read the server's calls in flight, on its metrics port alone."
  }

  assert {
    condition = (
      [for metric in module.genai_grpc[0].autoscaler.spec.metric : metric.type] == ["Resource", "Pods"] &&
      one(one(module.genai_grpc[0].autoscaler.spec.metric[1].pods).target).average_value == tostring(floor(tonumber(local.genai_grpc_env.GRPC_MAX_CONCURRENT_CALLS) * 60 / 100)) &&
      module.genai_grpc[0].autoscaler.gauge.spec.metrics[0].pod.containers[0].endpoint.port == tonumber(local.genai_grpc_env.METRICS_PORT) &&
      alltrue([for workload in [module.json_keys_grpc[0], module.authentication_rest[0], module.genai_sweep[0], module.platform_web["studio"]] : workload.autoscaler.gauge == null])
    )
    error_message = "GenAI's server alone must scale on its calls in flight, beside CPU, at 60% of its call cap per pod, read on its metrics port."
  }
}

run "runs_each_platform" {
  command = plan

  variables {
    custom_resources = true
  }

  assert {
    condition = alltrue([for platform, env in local.platform_env :
      length([for name in keys(env) : name if startswith(name, "SENTRY_") || startswith(name, "PUBLIC_SENTRY_")]) == 0 &&
      env.ORIGIN == "https://${local.platform_edges[platform].host}" &&
      env.ADDRESS_HEADER == "X-Forwarded-For" &&
      env.XFF_DEPTH == "2"
    ]) && local.platform_env.studio.ORIGIN == "https://studio.storyverse.fr"
    error_message = "Each platform must report nothing to Sentry, check form posts against its own host, and take the visitor's address the load balancer appends."
  }

  assert {
    condition = (
      toset(keys(local.platform_env)) == toset(["account", "studio"]) &&
      local.platform_env.studio.ACCOUNT_URL == local.platform_env.account.ORIGIN &&
      local.platform_env.account.STUDIO_URL == local.platform_env.studio.ORIGIN
    )
    error_message = "Studio's account link must open the account platform, and the account platform's app list Studio."
  }

  # A release without service tokens sends Google ID tokens when AUTHENTICATION_SERVICE_AUDIENCE is
  # set, which Authentication on the cluster cannot take.
  assert {
    condition = alltrue([for platform, env in local.platform_env :
      !contains(keys(env), "AUTHENTICATION_SERVICE_AUDIENCE") &&
      env.AUTHENTICATION_SERVICE_URL == "http://${module.authentication_rest[0].pod_labels["app.kubernetes.io/name"]}.authentication.svc:${local.authentication_env.REST_PORT}" &&
      contains(split(",", local.authentication_env.SERVICE_TOKEN_CALLERS), module.platform_web[platform].service_account) &&
      one(one(one(kubernetes_network_policy_v1.platform_web[platform].spec).egress).to).pod_selector[0].match_labels["app.kubernetes.io/name"] == module.authentication_rest[0].pod_labels["app.kubernetes.io/name"] &&
      one(one(one(kubernetes_network_policy_v1.platform_web[platform].spec).egress).ports).port == local.authentication_env.REST_PORT &&
      contains([for peer in one(one(kubernetes_network_policy_v1.authentication_rest.spec).ingress).from :
        "${one(peer.namespace_selector).match_labels["kubernetes.io/metadata.name"]}/${one(peer.pod_selector).match_labels["app.kubernetes.io/name"]}"
        if length(peer.namespace_selector) > 0
      ], "${platform}/${module.platform_web[platform].pod_labels["app.kubernetes.io/name"]}")
    ])
    error_message = "Each platform must call Authentication's API directly, as a caller Authentication admits."
  }
}

run "serves_each_platform_through_its_gateway" {
  command = plan

  variables {
    custom_resources = true
  }

  assert {
    condition = toset(keys(kubernetes_manifest.platform_gateway)) == toset(keys(local.platforms)) && alltrue([for platform, gateway in kubernetes_manifest.platform_gateway :
      gateway.manifest.spec.gatewayClassName == "gke-l7-global-external-managed" &&
      gateway.manifest.spec.addresses == [{ type = "NamedAddress", value = platform }] &&
      gateway.manifest.metadata.annotations["networking.gke.io/certmap"] == platform &&
      kubernetes_manifest.platform_gateway_policy[platform].manifest.spec.default.sslPolicy == platform &&
      alltrue([for listener in gateway.manifest.spec.listeners : listener.hostname == local.platform_edges[platform].host])
    ])
    error_message = "Each platform's Gateway must answer only for its host, on foundation's address, certificate map and TLS policy."
  }

  assert {
    condition = alltrue([for platform, route in kubernetes_manifest.platform_route :
      route.manifest.spec.hostnames == [local.platform_edges[platform].host] &&
      one(route.manifest.spec.parentRefs).sectionName == "https" &&
      one(one(route.manifest.spec.rules).backendRefs) == module.platform_web[platform].service &&
      one(kubernetes_manifest.platform_redirect[platform].manifest.spec.parentRefs).sectionName == "http" &&
      one(one(kubernetes_manifest.platform_redirect[platform].manifest.spec.rules).filters).requestRedirect.scheme == "https" &&
      length(keys(one(kubernetes_manifest.platform_redirect[platform].manifest.spec.rules))) == 1
    ])
    error_message = "HTTPS must reach each platform's Service, and plain HTTP must only redirect to HTTPS."
  }

  assert {
    condition = alltrue([for platform, check in kubernetes_manifest.platform_health_check :
      check.manifest.spec.targetRef.name == module.platform_web[platform].service.name &&
      check.manifest.spec.default.config.httpHealthCheck.requestPath == "/ping" &&
      check.manifest.spec.default.config.httpHealthCheck.port == module.platform_web[platform].service.port
    ]) && local.authentication_env.PLATFORM_AUTH_URL == local.platform_env.account.ORIGIN
    error_message = "The load balancer must check each platform on its probes' path, and Authentication's links must name a Gateway's host."
  }

  assert {
    condition = alltrue([for platform, policy in kubernetes_network_policy_v1.platform_web :
      length(one(policy.spec).ingress) == 1 &&
      toset([for peer in one(one(policy.spec).ingress).from : one(peer.ip_block).cidr]) == toset(["35.191.0.0/16", "130.211.0.0/22"]) &&
      alltrue([for peer in one(one(policy.spec).ingress).from : length(peer.pod_selector) == 0 && length(peer.namespace_selector) == 0]) &&
      one(one(one(policy.spec).ingress).ports).port == tostring(module.platform_web[platform].service.port)
    ])
    error_message = "Only Google's load balancer may reach each platform, on its port."
  }
}

run "checks_each_service_as_a_caller_it_admits" {
  command = plan

  variables {
    custom_resources = true
  }

  assert {
    condition = (
      toset(keys(kubernetes_job_v1.smoke)) == toset(["authentication", "genai", "json-keys"]) &&
      toset(keys(kubernetes_cron_job_v1.health)) == toset(keys(kubernetes_job_v1.smoke)) &&
      alltrue([for service, job in kubernetes_job_v1.smoke :
        job.wait_for_completion &&
        job.spec[0].backoff_limit == 0 &&
        one(job.spec[0].template[0].spec[0].container).args == tolist(["-c", file("../../../modules/smoke-check/smoke.sh")]) &&
        kubernetes_cron_job_v1.health[service].spec[0].schedule == "*/5 * * * *" &&
        kubernetes_cron_job_v1.health[service].spec[0].concurrency_policy == "Forbid" &&
        kubernetes_cron_job_v1.health[service].spec[0].job_template[0].spec[0].backoff_limit == 0
      ])
    )
    error_message = "Each service must get a smoke Job, which the deploy waits on, and a health CronJob every five minutes, both running the shared check once per run."
  }

  # Each Job's name follows what its pod runs, so a new image, script or setting runs it again.
  assert {
    condition = alltrue([for service, job in kubernetes_job_v1.smoke :
      job.metadata[0].name == "smoke-${substr(sha256(jsonencode([
        one(job.spec[0].template[0].spec[0].container).image,
        { for env in one(job.spec[0].template[0].spec[0].container).env : env.name => env.value },
        one(job.spec[0].template[0].spec[0].container).args[1],
      ])), 0, 12)}"
    ])
    error_message = "Each smoke Job's name must change with its image, its settings and the script."
  }

  assert {
    condition = alltrue([for service, target in {
      authentication = { workload = module.authentication_rest[0], env = local.authentication_env, image = "authentication/rest", policy = kubernetes_network_policy_v1.authentication_rest }
      genai          = { workload = module.genai_grpc[0], env = local.genai_grpc_env, image = "genai/grpc", policy = kubernetes_network_policy_v1.genai_grpc }
      json-keys      = { workload = module.json_keys_grpc[0], env = local.json_keys_env, image = "json-keys/grpc", policy = kubernetes_network_policy_v1.json_keys_grpc }
      } : alltrue([for pod in [kubernetes_job_v1.smoke[service].spec[0].template[0], kubernetes_cron_job_v1.health[service].spec[0].job_template[0].spec[0].template[0]] : (
        one(pod.spec[0].container).image == local.release_image[target.image] &&
        contains(split(",", target.env.SERVICE_TOKEN_CALLERS), "system:serviceaccount:${service}:${pod.spec[0].service_account_name}") &&
        one(one(one(pod.spec[0].volume[0].projected).sources).service_account_token).audience == target.env.SERVICE_TOKEN_AUDIENCE &&
        { for env in one(pod.spec[0].container).env : env.name => env.value }["SERVICE_TOKEN_PATH"] == "/var/run/secrets/tokens/${target.env.SERVICE_TOKEN_AUDIENCE}" &&
        { for env in one(pod.spec[0].container).env : env.name => env.value }["SERVICE_URL"] == "http://${target.workload.service.name}.${service}.svc:${target.workload.service.port}" &&
        contains(flatten([for rule in one(target.policy.spec).ingress : [for peer in rule.from : one(peer.pod_selector).match_labels["app.kubernetes.io/name"]] if contains([for port in rule.ports : port.port], tostring(target.workload.service.port))]), pod.metadata[0].labels["app.kubernetes.io/name"]) &&
        one(one(one(kubernetes_network_policy_v1.smoke[service].spec).egress).to).pod_selector[0].match_labels == tomap({ "app.kubernetes.io/name" = target.workload.pod_labels["app.kubernetes.io/name"] }) &&
        one(one(one(kubernetes_network_policy_v1.smoke[service].spec).egress).ports).port == tostring(target.workload.service.port) &&
        kubernetes_network_policy_v1.smoke[service].spec[0].pod_selector[0].match_labels == pod.metadata[0].labels
      )])
    ])
    error_message = "Each check must run in its service's image, call its Service with a token for its audience as a caller it admits, and reach only its pods, which admit it."
  }
}

run "skips_the_checks_during_a_planned_downtime" {
  command = plan

  variables {
    custom_resources = true
    downtime         = "{\"components\":[\"service-json-keys.grpc\"],\"start\":\"2026-11-02T06:00:00Z\",\"end\":\"2026-11-02T07:00:00Z\"}"
  }

  assert {
    condition = alltrue([for service, job in kubernetes_job_v1.smoke :
      lookup({ for env in one(job.spec[0].template[0].spec[0].container).env : env.name => env.value }, "DOWNTIME_START", null) == (service == "json-keys" ? "2026-11-02T06:00:00Z" : null) &&
      lookup({ for env in one(kubernetes_cron_job_v1.health[service].spec[0].job_template[0].spec[0].template[0].spec[0].container).env : env.name => env.value }, "DOWNTIME_START", null) == (service == "json-keys" ? "2026-11-02T06:00:00Z" : null)
    ])
    error_message = "A planned downtime must reach only its own service's checks, which skip from its start."
  }
}

run "lets_only_the_named_operators_run_maintenance" {
  command = plan

  variables {
    custom_resources = true
  }

  assert {
    condition = (
      kubernetes_cron_job_v1.scheduled["maintenance"].metadata[0].namespace == "authentication" &&
      kubernetes_cron_job_v1.scheduled["maintenance"].spec[0].suspend &&
      kubernetes_cron_job_v1.scheduled["maintenance"].spec[0].job_template[0].spec[0].active_deadline_seconds >= tonumber(trimsuffix(local.authentication_mail_env.SMTP_TIMEOUT, "s")) + 180 &&
      one(kubernetes_cron_job_v1.scheduled["maintenance"].spec[0].job_template[0].spec[0].template[0].spec[0].container).image == local.release_image["authentication/maintenance"] &&
      length(one(kubernetes_cron_job_v1.scheduled["maintenance"].spec[0].job_template[0].spec[0].template[0].spec[0].container).args) == 0 &&
      contains(kubernetes_manifest.internet_egress["smtp-relay"].manifest.spec.podSelector.matchExpressions[0].values, kubernetes_cron_job_v1.scheduled["maintenance"].spec[0].job_template[0].spec[0].template[0].metadata[0].labels["app.kubernetes.io/name"]) &&
      alltrue([for name, value in local.authentication_mail_env :
        { for env in one(kubernetes_cron_job_v1.scheduled["maintenance"].spec[0].job_template[0].spec[0].template[0].spec[0].container).env : env.name => env.value }[name] == local.authentication_env[name]
      ])
    )
    error_message = "The maintenance template must never run on its own, run Authentication's maintenance image with no operation, and send the API's mail through the relay within SMTP_TIMEOUT and Sentry's exit flush."
  }

  assert {
    condition = (
      toset([for subject in kubernetes_role_binding_v1.maintenance.subject : "${lower(subject.kind)}:${subject.name}"]) == toset(local.maintenance_principals) &&
      kubernetes_role_binding_v1.maintenance.role_ref[0].kind == "Role" &&
      alltrue([for rule in kubernetes_role_v1.maintenance.rule :
        !contains(rule.resources, "secrets") &&
        length(setsubtract(rule.verbs, ["create", "get", "list", "watch"])) == 0 &&
        (!contains(rule.verbs, "create") || toset(rule.resources) == toset(["jobs"])) &&
        (!contains(rule.resources, "cronjobs") || toset(rule.resource_names) == toset([kubernetes_cron_job_v1.scheduled["maintenance"].metadata[0].name]))
      ])
    )
    error_message = "Only foundation's maintenance principals may read the maintenance template and create Jobs in Authentication's namespace, never read its Secrets, and change nothing else."
  }

  assert {
    condition = (
      kubernetes_manifest.maintenance_policy.manifest.spec.failurePolicy == "Fail" &&
      alltrue([for email in local.maintenance_emails : strcontains(kubernetes_manifest.maintenance_policy.manifest.spec.matchConditions[0].expression, "\"${email}\"")]) &&
      length(setsubtract(["initContainers", "volumes", "serviceAccountName", "automountServiceAccountToken", "containers[0].image", "containers[0].command", "containers[0].env", "containers[0].envFrom", "containers[0].volumeMounts", "containers[0].lifecycle", "containers[0].livenessProbe", "containers[0].readinessProbe", "containers[0].startupProbe"], local.maintenance_kept_fields)) == 0 &&
      kubernetes_manifest.maintenance_policy_binding.manifest.spec.validationActions == ["Deny"] &&
      kubernetes_manifest.maintenance_policy_binding.manifest.spec.paramRef == {
        name                    = kubernetes_cron_job_v1.scheduled["maintenance"].metadata[0].name
        namespace               = kubernetes_cron_job_v1.scheduled["maintenance"].metadata[0].namespace
        parameterNotFoundAction = "Deny"
      }
    )
    error_message = "Admission must refuse an operator's Job that changes what the maintenance template runs, reads or runs as, and every one without the template."
  }
}

run "gives_each_service_its_own_budget" {
  command = plan

  assert {
    condition = (
      toset(keys(kubernetes_resource_quota_v1.service)) == toset(var.namespaces) &&
      alltrue([for name, quota in kubernetes_resource_quota_v1.service :
        quota.spec[0].hard["requests.cpu"] == var.service_budgets[name].cpu &&
        quota.spec[0].hard["requests.memory"] == var.service_budgets[name].memory &&
        quota.spec[0].hard["pods"] == tostring(var.service_budgets[name].pods)
      ])
    )
    error_message = "Each service's namespace must cap its pods' CPU and memory requests and its pod count at its own budget."
  }

  assert {
    condition = alltrue([for name in var.namespaces :
      kubernetes_limit_range_v1.service[name].spec[0].limit[0].type == "Container" &&
      length(kubernetes_limit_range_v1.service[name].spec[0].limit[0].default_request) == 2 &&
      try(length(kubernetes_limit_range_v1.service[name].spec[0].limit[0].default), 0) == 0
    ])
    error_message = "Each service's namespace must give a container without requests a small CPU and memory request, and no limit, or its quota refuses the pod."
  }
}

run "makes_no_openai_call_without_a_revision" {
  command = plan

  variables {
    custom_resources     = true
    genai_provider_check = null
  }

  assert {
    condition     = length(kubernetes_job_v1.provider_check) == 0
    error_message = "Without a revision, no provider check may call OpenAI."
  }
}

run "makes_one_openai_call_per_revision_as_a_caller_genai_admits" {
  command = plan

  variables {
    custom_resources     = true
    genai_provider_check = "rehearsal"
  }

  assert {
    condition = (
      length(kubernetes_job_v1.provider_check) == 1 &&
      kubernetes_job_v1.provider_check[0].metadata[0].name == "provider-check-${var.genai_provider_check}" &&
      kubernetes_job_v1.provider_check[0].wait_for_completion &&
      kubernetes_job_v1.provider_check[0].spec[0].backoff_limit == 0 &&
      kubernetes_job_v1.provider_check[0].spec[0].active_deadline_seconds < tonumber(trimsuffix(kubernetes_job_v1.provider_check[0].timeouts.create, "m")) * 60 &&
      one(kubernetes_job_v1.provider_check[0].spec[0].template[0].spec[0].container).args == tolist(["-c", file("provider-check.sh")])
    )
    error_message = "A revision must run one provider check, named after it, which never retries and ends before the deploy stops waiting on it."
  }

  assert {
    condition = alltrue([for pod in [kubernetes_job_v1.provider_check[0].spec[0].template[0]] : (
      kubernetes_job_v1.provider_check[0].metadata[0].namespace == "genai" &&
      one(pod.spec[0].container).image == local.release_image["genai/grpc"] &&
      contains(split(",", local.genai_grpc_env.SERVICE_TOKEN_CALLERS), "system:serviceaccount:genai:${pod.spec[0].service_account_name}") &&
      one(one(one(pod.spec[0].volume[0].projected).sources).service_account_token).audience == local.genai_grpc_env.SERVICE_TOKEN_AUDIENCE &&
      { for env in one(pod.spec[0].container).env : env.name => env.value }["SERVICE_TOKEN_PATH"] == "/var/run/secrets/tokens/${local.genai_grpc_env.SERVICE_TOKEN_AUDIENCE}" &&
      { for env in one(pod.spec[0].container).env : env.name => env.value }["SERVICE_URL"] == "http://${module.genai_grpc[0].service.name}.genai.svc:${module.genai_grpc[0].service.port}" &&
      contains(flatten([for rule in one(kubernetes_network_policy_v1.genai_grpc.spec).ingress : [for peer in rule.from : one(peer.pod_selector).match_labels["app.kubernetes.io/name"]] if contains([for port in rule.ports : port.port], tostring(module.genai_grpc[0].service.port))]), pod.metadata[0].labels["app.kubernetes.io/name"]) &&
      kubernetes_network_policy_v1.smoke["genai"].spec[0].pod_selector[0].match_labels == pod.metadata[0].labels
    )])
    error_message = "The provider check must run in GenAI's server image, call its Service with a token for its audience as a caller it admits, and reach only its pods, which admit it."
  }
}

run "skips_the_openai_call_during_a_planned_downtime" {
  command = plan

  variables {
    custom_resources     = true
    genai_provider_check = "rehearsal"
    downtime             = "{\"components\":[\"service-genai.grpc\"],\"start\":\"2026-11-02T06:00:00Z\",\"end\":\"2026-11-02T07:00:00Z\"}"
  }

  assert {
    condition     = lookup({ for env in one(kubernetes_job_v1.provider_check[0].spec[0].template[0].spec[0].container).env : env.name => env.value }, "DOWNTIME_START", null) == "2026-11-02T06:00:00Z"
    error_message = "GenAI's planned downtime must skip the provider check from its start."
  }
}
