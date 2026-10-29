# Kubernetes isolation replaces the trust-zone projects (a-novel/.github#522): Pod Security's
# restricted level and two admission policies in every namespace this root manages, and default-deny
# network policies in the services' namespaces. The deploy checks after each apply that admission
# still refuses what it must.
locals {
  pod_security = {
    "pod-security.kubernetes.io/enforce"         = "restricted"
    "pod-security.kubernetes.io/enforce-version" = "latest"
    "pod-security.kubernetes.io/audit"           = "restricted"
    "pod-security.kubernetes.io/warn"            = "restricted"
  }

  admitted_namespaces = sort(setunion(var.namespaces, local.addon_namespaces))

  # Images come only from our project's Artifact Registry, in any region, pinned by digest. A pod's
  # containers, init containers and ephemeral containers are different types, so each list gets its
  # own check.
  image_rule = "c.image.matches('^[a-z0-9-]+-docker[.]pkg[.]dev/${data.terraform_remote_state.foundation.outputs.workload_project_id}/') && c.image.contains('@sha256:')"

  admission_policies = {
    a-novel-images = {
      resources = ["pods", "pods/ephemeralcontainers"]
      expression = join(" && ", [
        "object.spec.containers.all(c, ${local.image_rule})",
        "(!has(object.spec.initContainers) || object.spec.initContainers.all(c, ${local.image_rule}))",
        "(!has(object.spec.ephemeralContainers) || object.spec.ephemeralContainers.all(c, ${local.image_rule}))",
      ])
      message = "Images must come from our Artifact Registry, pinned by digest."
    }
    # Load balancers come only through the gateway (a-novel/infra#1202), outside these namespaces.
    a-novel-load-balancers = {
      resources  = ["services"]
      expression = "object.spec.type != 'LoadBalancer'"
      message    = "Load balancers come only through the gateway."
    }
  }
}

resource "kubernetes_manifest" "admission_policy" {
  for_each = local.admission_policies

  manifest = {
    apiVersion = "admissionregistration.k8s.io/v1"
    kind       = "ValidatingAdmissionPolicy"
    metadata   = { name = each.key }
    spec = {
      failurePolicy = "Fail"
      matchConstraints = {
        resourceRules = [{ apiGroups = [""], apiVersions = ["v1"], operations = ["CREATE", "UPDATE"], resources = each.value.resources }]
      }
      validations = [{ expression = each.value.expression, message = each.value.message }]
    }
  }
}

resource "kubernetes_manifest" "admission_binding" {
  for_each = local.admission_policies

  manifest = {
    apiVersion = "admissionregistration.k8s.io/v1"
    kind       = "ValidatingAdmissionPolicyBinding"
    metadata   = { name = each.key }
    spec = {
      policyName        = kubernetes_manifest.admission_policy[each.key].manifest.metadata.name
      validationActions = ["Deny"]
      matchResources = {
        namespaceSelector = {
          matchExpressions = [{ key = "kubernetes.io/metadata.name", operator = "In", values = local.admitted_namespaces }]
        }
      }
    }
  }
}

# Nothing reaches a service's pods, and they reach nothing but DNS, until a policy of its own opens a
# path: its callers, its database, its egress allowlist hosts and the metadata server.
resource "kubernetes_network_policy_v1" "default_deny" {
  for_each = var.namespaces

  metadata {
    name      = "default-deny"
    namespace = kubernetes_namespace_v1.service[each.key].metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]

    # NodeLocal DNSCache, on by default since GKE 1.34.1, answers each node's queries for kube-dns'
    # address, and asks kube-dns for what it has not cached.
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
  }
}
