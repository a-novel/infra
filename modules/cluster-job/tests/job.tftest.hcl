mock_provider "kubernetes" {}

variables {
  name            = "smoke-9e9e871d055d"
  namespace       = "genai"
  labels          = { "app.kubernetes.io/name" = "smoke" }
  service_account = "smoke"
  container_name  = "smoke"
  image           = "europe-west9-docker.pkg.dev/a-novel-production-prod/a-novel-genai/service-genai/grpc@sha256:30df698ad643886f231dfdfd821e7731a19d53e3530c61a350c7d29f01f0a770"
  env             = { SERVICE_URL = "https://grpc.genai.svc:8443", PROTOCOL = "grpc" }
  secret_env = [
    { name = "PGUSER", secret = "database-app", key = "username" },
    { name = "PGPASSWORD", secret = "database-app", key = "password" },
  ]
  ca_secret               = "database-server-tls"
  service_token           = "genai"
  service_ca              = "services-ca"
  tmp_size                = "1Mi"
  resources               = { cpu = "50m", memory = "64Mi" }
  active_deadline_seconds = 300
  timeout                 = "6m"
}

# The mocked apply gives the next run this Job's pods to compare.
run "runs_one_restricted_job" {
  command = apply

  assert {
    condition     = output.cron_job == null && output.job.wait_for_completion && output.job.spec[0].backoff_limit == 0
    error_message = "Without a schedule, the module must run one Job, which the apply waits on and Kubernetes never retries."
  }

  assert {
    condition = (
      output.job.spec[0].template[0].spec[0].restart_policy == "Never" &&
      !output.job.spec[0].template[0].spec[0].automount_service_account_token &&
      !output.job.spec[0].template[0].spec[0].enable_service_links &&
      output.job.spec[0].template[0].spec[0].security_context[0].run_as_non_root &&
      output.job.spec[0].template[0].spec[0].security_context[0].seccomp_profile[0].type == "RuntimeDefault" &&
      one(output.job.spec[0].template[0].spec[0].container).security_context[0].run_as_non_root &&
      one(output.job.spec[0].template[0].spec[0].container).security_context[0].read_only_root_filesystem &&
      !one(output.job.spec[0].template[0].spec[0].container).security_context[0].allow_privilege_escalation &&
      one(output.job.spec[0].template[0].spec[0].container).security_context[0].capabilities[0].drop == tolist(["ALL"])
    )
    error_message = "A job's pods must run unprivileged, on a read-only filesystem, without a Kubernetes token or Service link variables, as Pod Security's restricted level requires."
  }

  assert {
    condition = (
      toset([for mount in one(output.job.spec[0].template[0].spec[0].container).volume_mount : mount.name]) == toset([for volume in output.job.spec[0].template[0].spec[0].volume : volume.name]) &&
      alltrue([for mount in one(output.job.spec[0].template[0].spec[0].container).volume_mount : coalesce(mount.read_only, false) == (mount.mount_path != "/tmp")]) &&
      [for item in one([for volume in output.job.spec[0].template[0].spec[0].volume : one(volume.secret).items if volume.name == "database-ca"]) : item.key] == ["ca.crt"] &&
      [for item in one([for volume in output.job.spec[0].template[0].spec[0].volume : one(volume.config_map).items if volume.name == "service-ca"]) : item.key] == ["ca.crt"] &&
      one([for volume in output.job.spec[0].template[0].spec[0].volume : one(volume.empty_dir).medium if volume.name == "tmp"]) == "Memory"
    )
    error_message = "Each mount must read a volume the pod declares, read-only but /tmp, which lives in memory, and each CA volume must expose only the CA's certificate."
  }

  assert {
    condition     = [for env in one(output.job.spec[0].template[0].spec[0].container).env : env.name] == ["PROTOCOL", "SERVICE_URL", "PGUSER", "PGPASSWORD"]
    error_message = "The plain variables must come first, then the Secrets' in the order given."
  }
}

run "runs_the_same_pods_on_a_schedule" {
  command = plan

  variables {
    schedule = "*/5 * * * *"
    job_pods = run.runs_one_restricted_job.job.spec[0].template[0]
  }

  assert {
    condition = (
      output.job == null &&
      output.cron_job.spec[0].timezone == "Etc/UTC" &&
      output.cron_job.spec[0].concurrency_policy == "Forbid" &&
      output.cron_job.spec[0].successful_jobs_history_limit == 1 &&
      output.cron_job.spec[0].job_template[0].spec[0].backoff_limit == 0
    )
    error_message = "A schedule must run a CronJob instead of a Job, in UTC, one run at a time, never retried, keeping only its last successful run."
  }

  # The mock fills each resource type's computed fields apart, so only the fields the module sets
  # are compared.
  assert {
    condition = (
      output.cron_job.spec[0].job_template[0].spec[0].template[0].metadata[0].labels == var.job_pods.metadata[0].labels &&
      alltrue([for field in ["restart_policy", "service_account_name", "automount_service_account_token", "enable_service_links", "security_context", "volume"] :
        output.cron_job.spec[0].job_template[0].spec[0].template[0].spec[0][field] == var.job_pods.spec[0][field]
      ]) &&
      alltrue([for field in ["name", "image", "command", "args", "env", "volume_mount", "resources", "security_context"] :
        one(output.cron_job.spec[0].job_template[0].spec[0].template[0].spec[0].container)[field] == one(var.job_pods.spec[0].container)[field]
      ])
    )
    error_message = "The CronJob's pods must be the Job's."
  }
}

run "mounts_only_what_the_job_reads" {
  command = plan

  variables {
    ca_secret     = null
    service_token = null
    service_ca    = null
    tmp_size      = null
  }

  assert {
    condition     = length(output.job.spec[0].template[0].spec[0].volume) == 0 && length(one(output.job.spec[0].template[0].spec[0].container).volume_mount) == 0
    error_message = "A job that reads no CA, token or files of its own must mount nothing."
  }
}

run "refuses_an_image_without_a_digest" {
  command = plan

  variables {
    image = "ghcr.io/a-novel/service-genai/grpc:v1.0.0"
  }

  expect_failures = [var.image]
}
