# Each workload reaches only its own internet hosts (a-novel/infra#1200). Foundation's firewall lets
# every node reach the whole egress allowlist, which the DNS allowlist also resolves. These policies
# narrow it to the pods calling each host, by the addresses the pods' own lookups return, so a host
# answering each client with other addresses still matches.
locals {
  internet_egress = {
    openai     = { namespace = "genai", pods = ["grpc", "sweep"], host = "api.openai.com", port = 443 }
    smtp-relay = { namespace = "authentication", pods = ["maintenance", "rest"], host = local.authentication_smtp.host, port = 587 }
    # The platforms' planned downtime document.
    github-raw         = { namespace = "studio", pods = ["web"], host = "raw.githubusercontent.com", port = 443 }
    github-raw-account = { namespace = "account", pods = ["web"], host = "raw.githubusercontent.com", port = 443 }
    # The Grafana Cloud stack, which receives every signal (alloy.tf).
    grafana-otlp = { namespace = "alloy", pods = ["alloy"], host = var.grafana_cloud.otlp_host, port = 443 }
  }
}

resource "kubernetes_manifest" "internet_egress" {
  for_each = var.custom_resources ? local.internet_egress : {}

  manifest = {
    apiVersion = "networking.gke.io/v1alpha1"
    kind       = "FQDNNetworkPolicy"
    metadata   = { name = each.key, namespace = local.namespace[each.value.namespace] }
    spec = {
      podSelector = { matchExpressions = [{ key = "app.kubernetes.io/name", operator = "In", values = each.value.pods }] }
      egress = [{
        matches = [{ name = each.value.host }]
        ports   = [{ protocol = "TCP", port = each.value.port }]
      }]
    }
  }
}
