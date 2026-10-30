# Only foundation's named operators run Authentication's maintenance operations. Each run is a Job
# copied from the suspended maintenance CronJob (scheduled-jobs.tf), whose arguments name the
# operation, as the setup runbook shows. Foundation's IAM only lets them reach the control plane.
locals {
  maintenance_principals = provider::terraform::decode_tfvars(file("${path.module}/../foundation/terraform.tfvars")).authentication_maintenance_principals
  maintenance_emails     = [for principal in local.maintenance_principals : split(":", principal)[1]]

  # These pod fields could run a command, read a Secret or act as another identity. A maintenance
  # Job keeps each one as its template sets it, or unset. Only the container's arguments differ.
  maintenance_kept_fields = [
    "initContainers",
    "volumes",
    "serviceAccountName",
    "automountServiceAccountToken",
    "containers[0].image",
    "containers[0].command",
    "containers[0].env",
    "containers[0].envFrom",
    "containers[0].volumeMounts",
    "containers[0].volumeDevices",
    "containers[0].lifecycle",
    "containers[0].livenessProbe",
    "containers[0].readinessProbe",
    "containers[0].startupProbe",
  ]
  # Pod labels select Services and network policies. A maintenance Job adds only the labels the Job
  # controller sets.
  maintenance_job_labels = ["batch.kubernetes.io/controller-uid", "batch.kubernetes.io/job-name", "controller-uid", "job-name"]
  maintenance_job_rules = concat(
    [
      "!has(object.spec.manualSelector) || !object.spec.manualSelector",
      "variables.pod.containers.size() == 1",
      "object.spec.template.metadata.labels.all(key, key in ${jsonencode(local.maintenance_job_labels)} || key in params.spec.jobTemplate.spec.template.metadata.labels && object.spec.template.metadata.labels[key] == params.spec.jobTemplate.spec.template.metadata.labels[key])",
    ],
    [for field in local.maintenance_kept_fields :
      "has(variables.pod.${field}) ? has(variables.template.${field}) && variables.pod.${field} == variables.template.${field} : !has(variables.template.${field})"
    ],
  )
}

# The operators read the template, create Jobs and follow their pods' logs.
resource "kubernetes_role_v1" "maintenance" {
  metadata {
    name      = "maintenance"
    namespace = kubernetes_namespace_v1.service["authentication"].metadata[0].name
  }

  rule {
    api_groups     = ["batch"]
    resources      = ["cronjobs"]
    resource_names = ["maintenance"]
    verbs          = ["get"]
  }

  rule {
    api_groups = ["batch"]
    resources  = ["jobs"]
    verbs      = ["create", "get", "list", "watch"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods", "pods/log"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_role_binding_v1" "maintenance" {
  metadata {
    name      = "maintenance"
    namespace = kubernetes_role_v1.maintenance.metadata[0].namespace
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.maintenance.metadata[0].name
  }

  # As operators.tf binds the database operators.
  dynamic "subject" {
    for_each = local.maintenance_principals

    content {
      api_group = "rbac.authorization.k8s.io"
      kind      = title(split(":", subject.value)[0])
      name      = split(":", subject.value)[1]
    }
  }
}

# A Job its creator writes can run any of our images with any command and read every Secret in the
# namespace. Admission refuses an operator's Job that changes its template beyond the container's
# arguments. Without the template, admission refuses every operator's Job.
resource "kubernetes_manifest" "maintenance_policy" {
  manifest = {
    apiVersion = "admissionregistration.k8s.io/v1"
    kind       = "ValidatingAdmissionPolicy"
    metadata   = { name = "a-novel-maintenance-jobs" }
    spec = {
      failurePolicy = "Fail"
      paramKind     = { apiVersion = "batch/v1", kind = "CronJob" }
      matchConstraints = {
        resourceRules = [{ apiGroups = ["batch"], apiVersions = ["v1"], operations = ["CREATE"], resources = ["jobs"] }]
      }
      # The deploy and the CronJob controller create the namespace's other Jobs.
      matchConditions = [{
        name       = "maintenance-operators"
        expression = "request.userInfo.username in ${jsonencode(local.maintenance_emails)} || has(request.userInfo.groups) && request.userInfo.groups.exists(group, group in ${jsonencode(local.maintenance_emails)})"
      }]
      variables = [
        { name = "pod", expression = "object.spec.template.spec" },
        { name = "template", expression = "params.spec.jobTemplate.spec.template.spec" },
      ]
      validations = [{
        expression = join(" && ", [for rule in local.maintenance_job_rules : "(${rule})"])
        message    = "A maintenance Job runs the maintenance CronJob's template, changing only its container's arguments."
      }]
    }
  }
}

resource "kubernetes_manifest" "maintenance_policy_binding" {
  manifest = {
    apiVersion = "admissionregistration.k8s.io/v1"
    kind       = "ValidatingAdmissionPolicyBinding"
    metadata   = { name = "a-novel-maintenance-jobs" }
    spec = {
      policyName        = kubernetes_manifest.maintenance_policy.manifest.metadata.name
      validationActions = ["Deny"]
      paramRef          = { name = "maintenance", namespace = kubernetes_role_v1.maintenance.metadata[0].namespace, parameterNotFoundAction = "Deny" }
      matchResources = {
        namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = kubernetes_role_v1.maintenance.metadata[0].namespace } }
      }
    }
  }
}
