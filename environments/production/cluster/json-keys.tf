# JSON Keys' gRPC server, which signs tokens, and its public REST API, which serves the public keys
# without authentication so the platforms verify access tokens on their own. Both run only once the
# operators' kinds exist, since they read Secrets the operators write.
locals {
  json_keys_env = merge(local.database_env["json-keys"], local.downtime_env["json-keys"], local.telemetry_env["json-keys"].api, {
    # Signing reads keys from a cache, so a few connections serve every pod.
    POSTGRES_MAX_OPEN_CONNS = "5"
    POSTGRES_MAX_IDLE_CONNS = "2"
    GRPC_PORT               = tostring(local.service_port)
    GOMEMLIMIT              = "400MiB"
    SERVICE_TOKEN_ISSUER    = local.service_token_issuer
    SERVICE_TOKEN_AUDIENCE  = "json-keys"
    SERVICE_TOKEN_CALLERS   = "system:serviceaccount:authentication:rest,system:serviceaccount:narrative-engine:rest,system:serviceaccount:profile:rest,system:serviceaccount:json-keys:smoke"
  })
  json_keys_rest_env = merge(local.database_env["json-keys"], local.downtime_env["json-keys"], local.telemetry_env["json-keys"].api, {
    # Each request reads the keys from the database, and the platforms cache them for 30 minutes, so
    # two connections serve every pod.
    POSTGRES_MAX_OPEN_CONNS = "2"
    POSTGRES_MAX_IDLE_CONNS = "1"
    REST_PORT               = tostring(local.service_port)
    GOMEMLIMIT              = "100MiB"
  })
}

module "json_keys_grpc" {
  source = "../../../modules/cluster-workload"
  count  = var.custom_resources ? 1 : 0

  name            = "grpc"
  namespace       = kubernetes_namespace_v1.service["json-keys"].metadata[0].name
  image           = local.release_image["json-keys/grpc"]
  port            = local.service_port
  tls             = { secret = kubernetes_manifest.service_server_certificate["json-keys/grpc"].manifest.spec.secretName }
  env             = local.json_keys_env
  secret_env      = merge(local.database_secret_env, { APP_MASTER_KEY = { secret = "secrets", key = "APP_MASTER_KEY" } })
  ca_secret       = kubernetes_manifest.database_server_certificate["json-keys"].manifest.spec.secretName
  resources       = { cpu = "100m", memory = "512Mi" }
  labels          = local.database_clients
  pod_annotations = local.database_client_annotations

  # Two keep signing up through a lost pod or node. A third, on CPU, follows Authentication's third,
  # which signs through it.
  replicas = { min = 2, max = 3 }

  depends_on = [kubernetes_job_v1.migrations, kubernetes_manifest.secrets]
}

# The REST server reads the database, never the master key.
module "json_keys_rest" {
  source = "../../../modules/cluster-workload"
  count  = var.custom_resources ? 1 : 0

  name             = "rest"
  namespace        = kubernetes_namespace_v1.service["json-keys"].metadata[0].name
  image            = local.release_image["json-keys/rest"]
  port             = local.service_port
  tls              = { secret = kubernetes_manifest.service_server_certificate["json-keys/rest"].manifest.spec.secretName }
  http_health_path = "/v2/ping"
  env              = local.json_keys_rest_env
  secret_env       = local.database_secret_env
  ca_secret        = kubernetes_manifest.database_server_certificate["json-keys"].manifest.spec.secretName
  resources        = { cpu = "50m", memory = "128Mi" }
  labels           = local.database_clients
  pod_annotations  = local.database_client_annotations

  # Two keep the keys served through a lost pod or node. A third, on CPU, absorbs a burst.
  replicas = { min = 2, max = 3 }

  depends_on = [kubernetes_job_v1.migrations]
}

# The Authentication, narrative-engine and profile APIs and JSON Keys' smoke check call the server,
# which reaches the issuer's keys through Google's restricted API addresses.
resource "kubernetes_network_policy_v1" "json_keys_grpc" {
  metadata {
    name      = "grpc"
    namespace = kubernetes_namespace_v1.service["json-keys"].metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = { "app.kubernetes.io/name" = "grpc" }
    }
    policy_types = ["Ingress", "Egress"]

    ingress {
      dynamic "from" {
        for_each = ["authentication", "narrative-engine", "profile"]

        content {
          namespace_selector {
            match_labels = { "kubernetes.io/metadata.name" = from.value }
          }
          pod_selector {
            match_labels = { "app.kubernetes.io/name" = "rest" }
          }
        }
      }
      from {
        pod_selector {
          match_labels = { "app.kubernetes.io/name" = "smoke" }
        }
      }

      ports {
        port     = tostring(local.service_port)
        protocol = "TCP"
      }
    }

    egress {
      dynamic "to" {
        for_each = local.cluster.google_api_ranges

        content {
          ip_block {
            cidr = to.value
          }
        }
      }

      ports {
        port     = "443"
        protocol = "TCP"
      }
    }
  }
}

# The platforms and JSON Keys' smoke check read the public keys. The API reaches only its database,
# through its database client's policy, so this policy opens no egress.
resource "kubernetes_network_policy_v1" "json_keys_rest" {
  metadata {
    name      = "rest"
    namespace = kubernetes_namespace_v1.service["json-keys"].metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = { "app.kubernetes.io/name" = "rest" }
    }
    policy_types = ["Ingress", "Egress"]

    ingress {
      dynamic "from" {
        for_each = local.platforms

        content {
          namespace_selector {
            match_labels = { "kubernetes.io/metadata.name" = from.key }
          }
          pod_selector {
            match_labels = { "app.kubernetes.io/name" = "web" }
          }
        }
      }
      from {
        pod_selector {
          match_labels = { "app.kubernetes.io/name" = "smoke" }
        }
      }

      ports {
        port     = tostring(local.service_port)
        protocol = "TCP"
      }
    }
  }
}
