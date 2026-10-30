# Alloy sends every signal to the Grafana Cloud stack (a-novel/.github#527): the workloads' traces
# and logs, the span metrics it derives from them, and the cluster's metrics and events. The
# k8s-monitoring chart runs it as a single pod through the Alloy Operator. Self-hosting later changes
# only its destination.
locals {
  # Each service's workloads send OTLP/HTTP to Alloy's receiver, inside the cluster and without
  # credentials, under their repository's name as on Cloud Run. a_novel.workload is api on a workload
  # that serves requests, and job on one a schedule starts or that runs itself.
  telemetry_env = { for service, roles in local.release_roles : service => { for workload in ["api", "job"] : workload => {
    OTEL                        = "true"
    OTEL_EXPORTER_OTLP_ENDPOINT = "http://alloy.${local.namespace["alloy"]}.svc:4318"
    OTEL_SERVICE_NAME           = split("/", local.release_images["${service}/${roles[0]}"].path)[0]
    OTEL_RESOURCE_ATTRIBUTES    = "a_novel.workload=${workload}"
  } } }

  # Each image as the charts take it: our cache of its registry, its path, its tag and its digest.
  alloy_images = { for name in ["alloy", "alloy_operator", "config_reloader", "kube_state_metrics"] : name => {
    registry   = local.cluster.image_registries[local.image_parts[name].host]
    repository = local.image_parts[name].path
    tag        = split("@", local.image_parts[name].tag)[0]
    digest     = split("@", local.image_parts[name].tag)[1]
  } }

  alloy_values = {
    cluster = { name = local.cluster.name }
    global  = { scrapeInterval = "60s" }

    destinations = {
      grafana-cloud = {
        type     = "otlp"
        protocol = "http"
        url      = "https://${var.grafana_cloud.otlp_host}/otlp"
        # The token reaches Alloy as an environment variable, so Alloy reads no Secret.
        auth   = { type = "basic", username = var.grafana_cloud.instance_id, passwordFrom = "sys.env(\"GRAFANA_CLOUD_TOKEN\")" }
        secret = { embed = true }
      }
      # Receives the traces beside Grafana and sends the span metrics it derives to it. The chart's
      # own span metrics can neither keep the root spans nor merge a service's pods.
      span-metrics = {
        type      = "custom"
        ecosystem = "otlp"
        traces    = { enabled = true, target = "otelcol.processor.filter.span_metrics.input" }
        config    = <<-EOT
          // Keeps the server spans and each trace's root, which a job's run is.
          otelcol.processor.filter "span_metrics" {
            error_mode = "ignore"
            traces {
              span = [`kind != SPAN_KIND_SERVER and not IsRootSpan()`]
            }
            output {
              traces = [otelcol.connector.spanmetrics.default.input]
            }
          }

          // Beside the service, span name and status: the innermost error's type and whether the
          // span served a request or ran a job. Every pod of a service adds to the same series.
          otelcol.connector.spanmetrics "default" {
            dimension {
              name = "error.type"
            }
            dimension {
              name = "a_novel.workload"
            }
            exclude_dimensions              = ["span.kind"]
            resource_metrics_key_attributes = ["service.name"]
            aggregation_cardinality_limit   = 1000
            histogram {
              unit = "s"
              explicit {
                buckets = ["50ms", "200ms", "1s", "5s", "30s"]
              }
            }
            output {
              metrics = [otelcol.processor.transform.span_metrics.input]
            }
          }

          // No series names a pod or an instance.
          otelcol.processor.transform "span_metrics" {
            error_mode = "ignore"
            metric_statements {
              context    = "resource"
              statements = [`keep_keys(attributes, ["service.name"])`]
            }
            output {
              metrics = [otelcol.processor.attributes.grafana_cloud.input]
            }
          }
        EOT
      }
    }

    # Nodes, containers and volumes from the kubelets and cAdvisor, and objects from
    # kube-state-metrics, all in this root's namespaces. Node Exporter stays off: it needs the host's
    # filesystems and network, which Pod Security's restricted level refuses.
    clusterMetrics = {
      enabled      = true
      collector    = "alloy"
      destinations = ["grafana-cloud"]
      cadvisor     = { metricsTuning = { includeNamespaces = local.admitted_namespaces } }
    }

    # The Kubernetes events. Pod logs stay off, since the workloads send their own.
    clusterEvents = {
      enabled      = true
      collector    = "alloy"
      destinations = ["grafana-cloud"]
      namespaces   = local.admitted_namespaces
    }

    # The databases' pods, which CloudNativePG annotates for it (databases.tf). Each instance's
    # settings cost hundreds of series.
    annotationAutodiscovery = {
      enabled       = true
      collector     = "alloy"
      destinations  = ["grafana-cloud"]
      namespaces    = sort(keys(var.databases))
      services      = { enabled = false }
      bearerToken   = { enabled = false }
      metricsTuning = { excludeMetrics = ["cnpg_pg_settings_setting"] }
    }

    # The receiver of the workloads' traces and logs. Its host-info metrics stay off, since App
    # Observability, which reads them, bills each host.
    applicationObservability = {
      enabled      = true
      collector    = "alloy"
      destinations = ["grafana-cloud", "span-metrics"]
      receivers    = { otlp = { http = { enabled = true, port = 4318 } } }
      # The spans keep their own host, which would otherwise name Alloy's pod.
      processors = { resourceDetection = { system = { enabled = false } } }
      connectors = { grafanaCloudMetrics = { enabled = false } }
    }

    # Only the kinds the chart's dashboards read, in this root's namespaces. It reads no Secret and no
    # ConfigMap.
    telemetryServices = {
      kube-state-metrics = {
        deploy     = true
        image      = { registry = local.alloy_images.kube_state_metrics.registry, repository = local.alloy_images.kube_state_metrics.repository, tag = local.alloy_images.kube_state_metrics.tag, sha = local.alloy_images.kube_state_metrics.digest }
        namespaces = join(",", local.admitted_namespaces)
        collectors = ["cronjobs", "daemonsets", "deployments", "horizontalpodautoscalers", "jobs", "namespaces", "nodes", "persistentvolumeclaims", "persistentvolumes", "poddisruptionbudgets", "pods", "replicasets", "resourcequotas", "statefulsets"]
        resources  = { requests = { cpu = "10m", memory = "128Mi" }, limits = { memory = "128Mi" } }
      }
    }

    # One pod, so cluster events, scrapes and span metrics each come from a single collector. The
    # workloads' exporters retry while it restarts. More pods need a tier that routes each service's
    # spans to one of them.
    collectors = {
      alloy = {
        presets = ["singleton"]
        image   = { registry = local.alloy_images.alloy.registry, repository = local.alloy_images.alloy.repository, digest = local.alloy_images.alloy.digest }
        alloy = {
          enableReporting = false
          extraPorts      = [{ name = "otlp-http", port = 4318, targetPort = 4318, protocol = "TCP" }]
          extraEnv        = [{ name = "GRAFANA_CLOUD_TOKEN", valueFrom = { secretKeyRef = { name = "secrets", key = "GRAFANA_CLOUD_TOKEN" } } }]
          # The image's own unprivileged user.
          securityContext = {
            runAsNonRoot             = true
            runAsUser                = 473
            runAsGroup               = 473
            allowPrivilegeEscalation = false
            readOnlyRootFilesystem   = true
            capabilities             = { drop = ["ALL"], add = null }
            seccompProfile           = { type = "RuntimeDefault" }
          }
          mounts    = { extra = [{ name = "storage", mountPath = "/tmp/alloy" }] }
          resources = { requests = { cpu = "100m", memory = "512Mi" }, limits = { memory = "512Mi" } }
        }
        controller     = { volumes = { extra = [{ name = "storage", emptyDir = {} }] } }
        configReloader = { image = { registry = local.alloy_images.config_reloader.registry, repository = local.alloy_images.config_reloader.repository, tag = local.alloy_images.config_reloader.tag, digest = local.alloy_images.config_reloader.digest } }
        # The operator manages only its own namespace, so this root grants Alloy's cluster reads.
        rbac           = { create = false }
        serviceAccount = { create = false, name = kubernetes_service_account_v1.alloy.metadata[0].name }
      }
    }

    # The operator manages Alloy in its own namespace alone, with no cluster-wide role. Its removal
    # hooks guard only an uninstall, which must then delete the Alloy resource before the operator.
    alloy-operator = {
      image               = { registry = local.alloy_images.alloy_operator.registry, repository = local.alloy_images.alloy_operator.repository, digest = local.alloy_images.alloy_operator.digest }
      ownNamespaceOnly    = true
      rbac                = { createClusterRoles = false }
      podSecurityContext  = { runAsNonRoot = true, runAsUser = 65532, runAsGroup = 65532, seccompProfile = { type = "RuntimeDefault" } }
      waitForAlloyRemoval = { enabled = false }
    }
  }
}

# Alloy discovers the nodes and the pods, scrapes the kubelets and reads the events. It reads no
# Secret and no ConfigMap.
resource "kubernetes_service_account_v1" "alloy" {
  metadata {
    name      = "alloy"
    namespace = local.namespace["alloy"]
  }
}

resource "kubernetes_cluster_role_v1" "alloy" {
  metadata {
    name = "alloy"
  }

  rule {
    api_groups = [""]
    resources  = ["endpoints", "events", "namespaces", "nodes", "nodes/metrics", "pods", "services"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["apps"]
    resources  = ["replicasets"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["discovery.k8s.io"]
    resources  = ["endpointslices"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "alloy" {
  metadata {
    name = "alloy"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.alloy.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.alloy.metadata[0].name
    namespace = kubernetes_service_account_v1.alloy.metadata[0].namespace
  }
}

resource "helm_release" "alloy" {
  name       = "alloy"
  namespace  = local.namespace["alloy"]
  repository = "https://grafana.github.io/helm-charts"
  chart      = "k8s-monitoring"
  version    = "4.5.4"

  values = [yamlencode(local.alloy_values)]

  depends_on = [kubernetes_cluster_role_binding_v1.alloy]
}

# The services' pods send to the receiver. Alloy reaches the API server and the kubelets in the node
# range, kube-state-metrics, the databases' metrics, and Grafana (egress.tf).
resource "kubernetes_network_policy_v1" "alloy" {
  metadata {
    name      = "alloy"
    namespace = local.namespace["alloy"]
  }

  spec {
    pod_selector {
      match_labels = { "app.kubernetes.io/name" = "alloy" }
    }
    policy_types = ["Ingress", "Egress"]

    ingress {
      from {
        namespace_selector {
          match_expressions {
            key      = "kubernetes.io/metadata.name"
            operator = "In"
            values   = sort(var.namespaces)
          }
        }
      }

      ports {
        port     = "4318"
        protocol = "TCP"
      }
    }

    # As every service's pods, through the node's DNS cache.
    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "kube-system" }
        }
        pod_selector {
          match_expressions {
            key      = "k8s-app"
            operator = "In"
            values   = ["kube-dns", "node-local-dns"]
          }
        }
      }

      ports {
        port     = "53"
        protocol = "UDP"
      }

      ports {
        port     = "53"
        protocol = "TCP"
      }
    }

    egress {
      to {
        ip_block {
          cidr = local.cluster.node_range
        }
      }

      dynamic "ports" {
        for_each = ["443", "10250"]
        content {
          port     = ports.value
          protocol = "TCP"
        }
      }
    }

    egress {
      to {
        pod_selector {
          match_labels = { "app.kubernetes.io/name" = "kube-state-metrics" }
        }
      }

      ports {
        port     = "8080"
        protocol = "TCP"
      }
    }

    egress {
      to {
        namespace_selector {
          match_expressions {
            key      = "kubernetes.io/metadata.name"
            operator = "In"
            values   = sort(keys(var.databases))
          }
        }
        pod_selector {
          match_labels = local.database_pods
        }
      }

      ports {
        port     = "9187"
        protocol = "TCP"
      }
    }
  }
}

# Every pod of a service may send its telemetry to the receiver.
resource "kubernetes_network_policy_v1" "telemetry" {
  for_each = var.namespaces

  metadata {
    name      = "telemetry"
    namespace = local.namespace[each.key]
  }

  spec {
    pod_selector {}
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = local.namespace["alloy"] }
        }
        pod_selector {
          match_labels = kubernetes_network_policy_v1.alloy.spec[0].pod_selector[0].match_labels
        }
      }

      ports {
        port     = "4318"
        protocol = "TCP"
      }
    }
  }
}
