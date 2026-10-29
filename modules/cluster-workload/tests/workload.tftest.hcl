mock_provider "kubernetes" {}

variables {
  name      = "grpc"
  namespace = "json-keys"
  image     = "europe-west1-docker.pkg.dev/a-novel-production-prod/agora-json-keys-private-production/service-json-keys/grpc@sha256:30df698ad643886f231dfdfd821e7731a19d53e3530c61a350c7d29f01f0a770"
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
      one(one(one(kubernetes_deployment_v1.workload.spec).template[0].spec).security_context).run_as_non_root &&
      one(one(one(one(kubernetes_deployment_v1.workload.spec).template[0].spec).container).security_context).run_as_non_root &&
      one(one(one(one(kubernetes_deployment_v1.workload.spec).template[0].spec).container).security_context).read_only_root_filesystem &&
      !one(one(one(one(kubernetes_deployment_v1.workload.spec).template[0].spec).container).security_context).allow_privilege_escalation &&
      one(one(one(one(one(kubernetes_deployment_v1.workload.spec).template[0].spec).container).security_context).capabilities).drop == tolist(["ALL"])
    )
    error_message = "A workload must run unprivileged, on a read-only filesystem, without a Kubernetes token."
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
}

run "serves_http_with_service_tokens" {
  command = plan

  variables {
    http_health_path = "/v2/ping"
    service_tokens   = { json-keys = "SERVICE_TOKEN_PATH" }
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
}
