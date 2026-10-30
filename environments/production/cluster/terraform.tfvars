custom_resources = true

# Each new database lineage archives under a new name: Barman refuses an archive another database's
# WAL already fills, and the buckets' retention keeps that WAL a week.
backup_server_name = "database-paris-2"

namespaces = [
  "authentication",
  "genai",
  "json-keys",
  "studio",
]

# Each add-on's images, pinned by digest. Renovate moves them with their chart's version. A blank
# line separates pins of different repositories, so concurrent update pull requests merge cleanly.
addon_images = {
  cert_manager_controller = "quay.io/jetstack/cert-manager-controller:v1.21.2@sha256:70f532fd9cfde0b09d55687200942399d89838bc2d5d5b45152eb799a15912b8"
  cert_manager_webhook    = "quay.io/jetstack/cert-manager-webhook:v1.21.2@sha256:a60e2dac46dbb8a7f3df95c54ce941012f54c2fe022f0ee55aaa1ab40ed957ae"
  cert_manager_cainjector = "quay.io/jetstack/cert-manager-cainjector:v1.21.2@sha256:c85268c64f2e0e76684bf5fe8906caff34b82523561c6affe0fae3546bd87562"

  cloudnative_pg = "ghcr.io/cloudnative-pg/cloudnative-pg:1.30.1@sha256:923c267ec29636db3bee20f993d0ec4973fa22998e1adad37da79e4d32b5bc07"

  plugin_barman_cloud = "ghcr.io/cloudnative-pg/plugin-barman-cloud:v0.15.1@sha256:c75acad19a36e8176cfe2885761ff1b836c6ef977d7257e298c99a28b5c302ef"

  plugin_barman_cloud_sidecar = "ghcr.io/cloudnative-pg/plugin-barman-cloud-sidecar:v0.15.1@sha256:2287a793a804db751edd0d07d44cd549e357677e98a800eb12e2cf7c0d53f9b0"

  external_secrets = "ghcr.io/external-secrets/external-secrets:v2.13.0@sha256:f799d87a6a959e597a4ba7a8d2379886292c3fcfbee678f7dc2d3566051bcb96"

  # The images the k8s-monitoring chart runs, which move with it.
  alloy              = "docker.io/grafana/alloy:v1.21.2@sha256:89a5a320168387336b9ac3c850609c3ba7757eadd4ae5f1d819deb35e9854b18"
  alloy_operator     = "ghcr.io/grafana/alloy-operator:1.14.2@sha256:44afd94d078432336e753da3da2d3d5f130dbe930c9ea53b4839363878f0ab09"
  config_reloader    = "quay.io/prometheus-operator/prometheus-config-reloader:v0.94.2@sha256:a1897c67478bc23434534e91ad3855280771196b1daf17144db9dbcb655bef71"
  kube_state_metrics = "registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.20.0@sha256:42cfe3723a5f058171c627537fb57a3ea0f26e4380fa18555a95cb1a1b4cfc5b"
}

# The production stack, which Alloy sends every signal to with its push token.
grafana_cloud = {
  instance_id = "1896612"
  otlp_host   = "otlp-gateway-prod-eu-west-2.grafana.net"
}

# Each instance gets today's database host CPU and memory. Each host's data held about 0.1 GiB on
# 2026-10-29, so the volumes start small and grow in place; the room above the data also absorbs
# WAL while archiving stalls. GenAI's purge bounds its payloads of up to 24 MiB.
databases = {
  authentication = { cpu = "750m", memory = "1536Mi", storage = "30Gi", max_connections = 50, extensions = ["uuid-ossp"] }
  genai          = { cpu = "1500m", memory = "6Gi", storage = "20Gi", max_connections = 150, extensions = ["pg_cron", "uuid-ossp"] }
  json-keys      = { cpu = "750m", memory = "1536Mi", storage = "10Gi", max_connections = 50, extensions = ["uuid-ossp"] }
}

# The database passwords come from CloudNativePG's database-app Secrets, so only these come from
# Secret Manager.
secrets = {
  alloy     = { GRAFANA_CLOUD_TOKEN = "push-token" }
  genai     = { OPENAI_API_KEY = "openai-api-key" }
  json-keys = { APP_MASTER_KEY = "app-master-key" }
}

addon_secret_versions = {
  alloy = { push-token = 1 }
}
