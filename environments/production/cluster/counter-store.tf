# Authentication's rate-limit counter store (a-novel/.github#550): one Valkey instance, from the
# official chart, that holds only httprate's counters. Each counter expires three windows after it
# starts, so the store keeps nothing on disk, and a restart only resets the current windows.
locals {
  # The chart's selector labels.
  counter_store_pods = { "app.kubernetes.io/name" = "valkey" }

  # The commands httprate sends: MGET reads a key's current and previous windows, and INCRBY and
  # EXPIRE count a request in one MULTI transaction. PING checks the store.
  counter_store_commands = ["mget", "incrby", "expire", "multi", "exec", "ping"]

  # Each image as the chart takes it: our cache of its registry, its path, and its tag with its
  # digest.
  counter_store_images = { for name in ["valkey", "redis_exporter"] : name => {
    registry   = local.cluster.image_registries[local.image_parts[name].host]
    repository = local.image_parts[name].path
    tag        = local.image_parts[name].tag
  } }

  # One pod, with redis_exporter beside Valkey for Alloy to scrape (alloy.tf). Once its 64 MiB fill,
  # Valkey evicts the least recently used counters first, which only loosens their limits.
  counter_store_values = {
    image          = local.counter_store_images.valkey
    resources      = { requests = { cpu = "50m", memory = "128Mi" }, limits = { memory = "128Mi" } }
    podAnnotations = { "k8s.grafana.com/scrape" = "true", "k8s.grafana.com/metrics.portName" = "metrics" }
    valkeyConfig   = <<-EOT
      maxmemory 64mb
      maxmemory-policy allkeys-lru
      save ""
      appendonly no
    EOT

    # Each user's password comes from the Secret External Secrets generates.
    auth = {
      enabled             = true
      usersExistingSecret = "valkey-users"
      aclUsers = {
        # The chart requires a default user and gives the exporter that user's password key. The
        # default user is off and keeps no password, so the key logs in only as the exporter.
        default = { passwordKey = "exporter", permissions = "off resetpass" }
        # httprate's commands on its own keys. AUTH and HELLO need no grant, and go-redis sends
        # CLIENT SETINFO as it connects.
        limiter = { permissions = "~httprate:* -@all ${join(" ", [for command in local.counter_store_commands : "+${command}"])} +client|setinfo" }
        # The statistics the exporter reads on every scrape, whatever its flags, and no key.
        exporter = { permissions = "-@all +info +slowlog|len +slowlog|get +commandlog|len +command|info" }
      }
    }

    metrics = {
      enabled = true
      exporter = {
        image = local.counter_store_images.redis_exporter
        # As its own user, with no CONFIG, CLIENT or LATENCY call, which its ACL refuses, and no Go
        # runtime series.
        args            = ["--redis.user=exporter", "--config-command=-", "--set-client-name=false", "--exclude-latency-histogram-metrics", "--redis-only-metrics"]
        resources       = { requests = { cpu = "10m", memory = "64Mi" }, limits = { memory = "64Mi" } }
        securityContext = { runAsNonRoot = true, allowPrivilegeEscalation = false, readOnlyRootFilesystem = true, capabilities = { drop = ["ALL"] } }
      }
      # Alloy scrapes the pod itself.
      service = { enabled = false }
    }
  }
}

# Each ACL user's password, in letters and digits, which every client and URL takes as they are.
resource "kubernetes_manifest" "counter_store_passwords" {
  count = var.custom_resources ? 1 : 0

  manifest = {
    apiVersion = "generators.external-secrets.io/v1alpha1"
    kind       = "Password"
    metadata   = { name = "valkey-users", namespace = local.namespace["authentication"] }
    spec       = { length = 32, symbols = 0, noUpper = false, allowRepeat = true, secretKeys = ["exporter", "limiter"] }
  }
}

# External Secrets generates the passwords once into the users' Secret, under each user's name, so
# neither state nor a plan holds them.
resource "kubernetes_manifest" "counter_store_users" {
  count = var.custom_resources ? 1 : 0

  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata   = { name = "valkey-users", namespace = local.namespace["authentication"] }
    spec = {
      refreshPolicy = "CreatedOnce"
      target        = { name = local.counter_store_values.auth.usersExistingSecret, creationPolicy = "Owner" }
      dataFrom = [{ sourceRef = { generatorRef = {
        apiVersion = kubernetes_manifest.counter_store_passwords[0].manifest.apiVersion
        kind       = kubernetes_manifest.counter_store_passwords[0].manifest.kind
        name       = kubernetes_manifest.counter_store_passwords[0].manifest.metadata.name
      } } }]
    }
  }

  wait {
    condition {
      type   = "Ready"
      status = "True"
    }
  }
}

resource "helm_release" "counter_store" {
  count = var.custom_resources ? 1 : 0

  name       = "valkey"
  namespace  = local.namespace["authentication"]
  repository = "https://valkey.io/valkey-helm/"
  chart      = "valkey"
  version    = "0.12.1"

  values = [yamlencode(local.counter_store_values)]

  # Valkey reads its users' passwords as it starts.
  depends_on = [kubernetes_manifest.counter_store_users]
}

# Authentication's API pods reach the store, and Alloy its exporter. The store calls nothing, so its
# policy opens no egress.
resource "kubernetes_network_policy_v1" "counter_store" {
  metadata {
    name      = "valkey"
    namespace = local.namespace["authentication"]
  }

  spec {
    pod_selector {
      match_labels = local.counter_store_pods
    }
    policy_types = ["Ingress", "Egress"]

    ingress {
      from {
        pod_selector {
          match_labels = kubernetes_network_policy_v1.authentication_rest.spec[0].pod_selector[0].match_labels
        }
      }

      ports {
        port     = "6379"
        protocol = "TCP"
      }
    }

    ingress {
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = local.namespace["alloy"] }
        }
        pod_selector {
          match_labels = kubernetes_network_policy_v1.alloy.spec[0].pod_selector[0].match_labels
        }
      }

      ports {
        port     = "9121"
        protocol = "TCP"
      }
    }
  }
}
