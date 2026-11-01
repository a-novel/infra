mock_provider "kubernetes" {}

variables {
  name      = "grpc"
  namespace = "json-keys"
  image     = "europe-west9-docker.pkg.dev/a-novel-production-prod/a-novel-json-keys/service-json-keys/grpc@sha256:30df698ad643886f231dfdfd821e7731a19d53e3530c61a350c7d29f01f0a770"
  port      = 8080
  ca_secret = "database-server-tls"
  resources = { cpu = "100m", memory = "512Mi" }
  replicas  = { min = 2, max = 2 }
}

run "runs_unprivileged" {
  command = plan

  assert {
    condition = (
      !kubernetes_service_account_v1.workload.automount_service_account_token &&
      !one(one(kubernetes_deployment_v1.workload.spec).template[0].spec).automount_service_account_token &&
      !one(one(kubernetes_deployment_v1.workload.spec).template[0].spec).enable_service_links &&
      one(one(one(kubernetes_deployment_v1.workload.spec).template[0].spec).security_context).run_as_non_root &&
      one(one(one(one(kubernetes_deployment_v1.workload.spec).template[0].spec).container).security_context).run_as_non_root &&
      one(one(one(one(kubernetes_deployment_v1.workload.spec).template[0].spec).container).security_context).read_only_root_filesystem &&
      !one(one(one(one(kubernetes_deployment_v1.workload.spec).template[0].spec).container).security_context).allow_privilege_escalation &&
      one(one(one(one(one(kubernetes_deployment_v1.workload.spec).template[0].spec).container).security_context).capabilities).drop == tolist(["ALL"])
    )
    error_message = "A workload must run unprivileged, on a read-only filesystem, without a Kubernetes token or Service link variables."
  }

  assert {
    condition     = length(kubernetes_pod_disruption_budget_v1.workload) == 1 && length(kubernetes_horizontal_pod_autoscaler_v2.workload) == 0
    error_message = "A fixed count of pods gets a disruption budget and no autoscaler."
  }

  assert {
    condition = (
      one(one(one(one(one(kubernetes_deployment_v1.workload.spec).template[0].spec).container).readiness_probe).grpc).port == 8080 &&
      length(one(one(one(one(kubernetes_deployment_v1.workload.spec).template[0].spec).container).readiness_probe).http_get) == 0 &&
      length(one(one(kubernetes_deployment_v1.workload.spec).template[0].spec).volume) == 1
    )
    error_message = "A gRPC workload's probes must call its health service, and a workload that calls nothing carries no token."
  }

  assert {
    condition = (
      output.service.name == kubernetes_service_v1.workload.metadata[0].name &&
      output.service.port == one(one(kubernetes_service_v1.workload.spec).port).port &&
      one(one(kubernetes_service_v1.workload.spec).port).target_port == tostring(var.port)
    )
    error_message = "The Service output must name the Service and the port it serves."
  }

  assert {
    condition     = one(kubernetes_service_v1.workload.spec).cluster_ip == "None"
    error_message = "A gRPC workload's Service must be headless, so its callers see every ready pod."
  }

  assert {
    condition = (
      one(one(one(one(kubernetes_deployment_v1.workload.spec).template[0].spec).volume).secret).secret_name == "database-server-tls" &&
      [for item in one(one(one(one(kubernetes_deployment_v1.workload.spec).template[0].spec).volume).secret).items : item.key] == ["ca.crt"] &&
      one([for env in one(one(one(kubernetes_deployment_v1.workload.spec).template[0].spec).container).env : env.value if env.name == "SSL_CERT_DIR"]) == "/etc/ssl/certs:${one(one(one(one(kubernetes_deployment_v1.workload.spec).template[0].spec).container).volume_mount).mount_path}"
    )
    error_message = "A workload must trust only the CA's certificate from its Secret, beside the system roots."
  }
}

run "scales_between_bounds" {
  command = plan

  variables {
    replicas = { min = 1, max = 4 }
  }

  assert {
    condition     = length(kubernetes_pod_disruption_budget_v1.workload) == 0 && one(kubernetes_horizontal_pod_autoscaler_v2.workload).spec[0].max_replicas == 4
    error_message = "A single pod gets no budget, which would block drains, and bounds apart get an autoscaler."
  }

  assert {
    condition = (
      [for metric in one(kubernetes_horizontal_pod_autoscaler_v2.workload).spec[0].metric : metric.type] == ["Resource"] &&
      length(kubernetes_manifest.scaling_gauge) == 0 &&
      length(one(one(one(kubernetes_deployment_v1.workload.spec).template[0].spec).container).port) == 1 &&
      output.autoscaler.gauge == null
    )
    error_message = "A workload without a scaling gauge must scale on CPU alone, and serve no metrics port."
  }

  assert {
    condition = (
      alltrue([for rules in values(one(one(kubernetes_horizontal_pod_autoscaler_v2.workload).spec[0].behavior)) : alltrue([for policy in one(rules).policy : policy.type == "Pods" && policy.value == 1 && policy.period_seconds >= 60])]) &&
      one(one(one(kubernetes_horizontal_pod_autoscaler_v2.workload).spec[0].behavior).scale_down).stabilization_window_seconds >= 300
    )
    error_message = "The autoscaler must add or remove one pod a minute at most, and remove one only after five minutes below its targets."
  }
}

run "scales_on_a_gauge" {
  command = plan

  variables {
    replicas      = { min = 1, max = 3 }
    scaling_gauge = { name = "grpc_server_calls_in_flight", port = 9090, average = 12 }
  }

  # GKE reads the gauge on its own port from every pod of the workload, and nothing else.
  assert {
    condition = (
      tomap(kubernetes_manifest.scaling_gauge[0].manifest.spec.metrics[0].pod.selector.matchLabels) == one(one(kubernetes_deployment_v1.workload.spec).selector).match_labels &&
      kubernetes_manifest.scaling_gauge[0].manifest.spec.metrics[0].pod.containers[0].endpoint.port == 9090 &&
      [for metric in kubernetes_manifest.scaling_gauge[0].manifest.spec.metrics[0].pod.containers[0].metrics : metric.gauge.prometheusMetricName] == ["grpc_server_calls_in_flight"] &&
      tomap({ for port in one(one(one(kubernetes_deployment_v1.workload.spec).template[0].spec).container).port : port.name => port.container_port }) == tomap({ grpc = 8080, metrics = 9090 }) &&
      [for port in one(kubernetes_service_v1.workload.spec).port : port.port] == [8080]
    )
    error_message = "An AutoscalingMetric must read the gauge on the pods' metrics port, which the Service leaves out."
  }

  assert {
    condition = (
      [for metric in one(kubernetes_horizontal_pod_autoscaler_v2.workload).spec[0].metric : metric.type] == ["Resource", "Pods"] &&
      one(one(one(kubernetes_horizontal_pod_autoscaler_v2.workload).spec[0].metric[0].resource).target).average_utilization == 70 &&
      one(one(one(kubernetes_horizontal_pod_autoscaler_v2.workload).spec[0].metric[1].pods).metric).name == "autoscaling.gke.io|${kubernetes_manifest.scaling_gauge[0].manifest.metadata.name}|${kubernetes_manifest.scaling_gauge[0].manifest.spec.metrics[0].pod.containers[0].metrics[0].gauge.name}" &&
      one(one(one(kubernetes_horizontal_pod_autoscaler_v2.workload).spec[0].metric[1].pods).target).average_value == "12" &&
      output.autoscaler.gauge == kubernetes_manifest.scaling_gauge[0].manifest
    )
    error_message = "The autoscaler must keep CPU at 70% and the gauge at its average per pod, read through the AutoscalingMetric."
  }
}

run "serves_http_with_service_tokens" {
  command = plan

  variables {
    http_health_path = "/v2/ping"
    service_tokens   = { json-keys = "SERVICE_TOKEN_PATH" }
    ca_secret        = null
  }

  assert {
    condition = alltrue([for probe in [
      one(one(one(one(kubernetes_deployment_v1.workload.spec).template[0].spec).container).startup_probe),
      one(one(one(one(kubernetes_deployment_v1.workload.spec).template[0].spec).container).readiness_probe),
    ] : one(probe.http_get).path == "/v2/ping" && one(probe.http_get).port == "8080" && length(probe.grpc) == 0])
    error_message = "An HTTP workload's probes must GET its health path, and call no gRPC health service."
  }

  assert {
    condition = (
      [for source in one([for volume in one(one(kubernetes_deployment_v1.workload.spec).template[0].spec).volume : one(volume.projected).sources if volume.name == "service-tokens"]) : one(source.service_account_token).audience] == ["json-keys"] &&
      one([for env in one(one(one(kubernetes_deployment_v1.workload.spec).template[0].spec).container).env : env.value if env.name == "SERVICE_TOKEN_PATH"]) == "${one([for mount in one(one(one(kubernetes_deployment_v1.workload.spec).template[0].spec).container).volume_mount : mount.mount_path if mount.name == "service-tokens"])}/json-keys"
    )
    error_message = "Each service token must name its callee's audience, at the path its variable names."
  }

  assert {
    condition = (
      length([for volume in one(one(kubernetes_deployment_v1.workload.spec).template[0].spec).volume : volume if volume.name == "database-ca"]) == 0 &&
      length([for env in one(one(one(kubernetes_deployment_v1.workload.spec).template[0].spec).container).env : env if env.name == "SSL_CERT_DIR"]) == 0
    )
    error_message = "A workload without a database trusts only the system roots."
  }
}

run "serves_tls_beside_plaintext" {
  command = plan

  variables {
    port       = 8443
    tls        = { secret = "grpc-server-tls", plaintext_port = 8080 }
    service_ca = "services-ca"
  }

  assert {
    condition = (
      { for env in one(one(one(kubernetes_deployment_v1.workload.spec).template[0].spec).container).env : env.name => env.value if startswith(env.name, "GRPC_") } == {
        GRPC_TLS_CERT_FILE  = "${one([for mount in one(one(one(kubernetes_deployment_v1.workload.spec).template[0].spec).container).volume_mount : mount.mount_path if mount.name == "server-tls"])}/tls.crt"
        GRPC_TLS_KEY_FILE   = "${one([for mount in one(one(one(kubernetes_deployment_v1.workload.spec).template[0].spec).container).volume_mount : mount.mount_path if mount.name == "server-tls"])}/tls.key"
        GRPC_PLAINTEXT_PORT = "8080"
      } &&
      one([for volume in one(one(kubernetes_deployment_v1.workload.spec).template[0].spec).volume : one(volume.secret).secret_name if volume.name == "server-tls"]) == "grpc-server-tls"
    )
    error_message = "A TLS server must name its certificate's files and its plaintext port to golib, from its Secret."
  }

  assert {
    condition = (
      toset([for port in one(kubernetes_service_v1.workload.spec).port : port.port]) == toset([8443, 8080]) &&
      toset([for port in one(one(one(kubernetes_deployment_v1.workload.spec).template[0].spec).container).port : port.container_port]) == toset([8443, 8080]) &&
      alltrue([for probe in [
        one(one(one(one(kubernetes_deployment_v1.workload.spec).template[0].spec).container).startup_probe),
        one(one(one(one(kubernetes_deployment_v1.workload.spec).template[0].spec).container).readiness_probe),
      ] : one(probe.grpc).port == 8080])
    )
    error_message = "A TLS server must serve both ports, and its probes must read the plaintext one."
  }

  assert {
    condition = (
      [for item in one([for volume in one(one(kubernetes_deployment_v1.workload.spec).template[0].spec).volume : one(volume.config_map) if volume.name == "service-ca"]).items : item.key] == ["ca.crt"] &&
      one([for env in one(one(one(kubernetes_deployment_v1.workload.spec).template[0].spec).container).env : env.value if env.name == "SSL_CERT_DIR"]) == "/etc/ssl/certs:/etc/database-ca:/etc/service-ca" &&
      one([for env in one(one(one(kubernetes_deployment_v1.workload.spec).template[0].spec).container).env : env.value if env.name == "NODE_EXTRA_CA_CERTS"]) == "/etc/service-ca/ca.crt"
    )
    error_message = "A workload that calls a service API must trust the services CA beside the system roots and its database's CA, in Go and in Node."
  }
}
