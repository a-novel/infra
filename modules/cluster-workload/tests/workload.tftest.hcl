mock_provider "kubernetes" {}

variables {
  name      = "grpc"
  namespace = "json-keys"
  image     = "europe-west1-docker.pkg.dev/a-novel-production-prod/agora-json-keys-private-production/service-json-keys/grpc@sha256:30df698ad643886f231dfdfd821e7731a19d53e3530c61a350c7d29f01f0a770"
  port      = 8080
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
