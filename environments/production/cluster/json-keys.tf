# JSON Keys on the cluster, which serves no one until the cutover (a-novel/.github#522). Its pods run
# only once the operators' kinds exist, since they read the database's and External Secrets' Secrets.
locals {
  json_keys_env = merge(local.database_env["json-keys"], local.downtime_env["json-keys"], local.telemetry_env["json-keys"].api, {
    # Signing reads keys from a cache, so a few connections serve every pod.
    POSTGRES_MAX_OPEN_CONNS = "5"
    POSTGRES_MAX_IDLE_CONNS = "2"
    GRPC_PORT               = "8080"
    GOMEMLIMIT              = "400MiB"
    SERVICE_TOKEN_ISSUER    = local.service_token_issuer
    SERVICE_TOKEN_AUDIENCE  = "json-keys"
    SERVICE_TOKEN_CALLERS   = "system:serviceaccount:authentication:rest,system:serviceaccount:json-keys:smoke"
  })
}

module "json_keys_grpc" {
  source = "../../../modules/cluster-workload"
  count  = var.custom_resources ? 1 : 0

  name            = "grpc"
  namespace       = kubernetes_namespace_v1.service["json-keys"].metadata[0].name
  image           = local.release_image["json-keys/grpc"]
  port            = 8080
  env             = local.json_keys_env
  secret_env      = merge(local.database_secret_env, { APP_MASTER_KEY = { secret = "secrets", key = "APP_MASTER_KEY" } })
  ca_secret       = kubernetes_manifest.database_server_certificate["json-keys"].manifest.spec.secretName
  resources       = { cpu = "100m", memory = "512Mi" }
  replicas        = { min = 2, max = 2 }
  labels          = local.database_clients
  pod_annotations = local.database_client_annotations

  depends_on = [kubernetes_job_v1.migrations, kubernetes_manifest.secrets]
}

# Authentication's API and JSON Keys' smoke check call the server, which reaches the issuer's keys
# through Google's restricted API addresses.
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
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "authentication" }
        }
        pod_selector {
          match_labels = { "app.kubernetes.io/name" = "rest" }
        }
      }
      from {
        pod_selector {
          match_labels = { "app.kubernetes.io/name" = "smoke" }
        }
      }

      ports {
        port     = "8080"
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
