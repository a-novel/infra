# Ops basics

This document is about the ideas behind this repository, which every runbook relies on. Read it
before the [architecture](architecture.md) and the [runbooks](runbooks/README.md).

## OpenTofu

**OpenTofu** is the open-source fork of Terraform. You declare resources in `.tf` files. OpenTofu
compares them with what exists, and makes the API calls that close the gap.

| Term                   | Meaning                                                                                    |
| ---------------------- | ------------------------------------------------------------------------------------------ |
| **Provider**           | A plugin that talks to an API, pinned in each root's `versions.tf`.                        |
| **Resource**           | One object to manage, such as a node pool, a bucket or an IAM grant.                       |
| **Data source**        | A read-only lookup of something managed elsewhere.                                         |
| **Root**               | A directory you run `tofu` in, with its own state.                                         |
| **Module**             | A reusable directory of resources that roots call, with no state of its own.               |
| **State**              | A JSON file recording what OpenTofu manages. Each root's lives in one GCS bucket.          |
| **Plan**               | The computed difference. Nothing changes until **apply**.                                  |
| **Lock file**          | `.terraform.lock.hcl`, the exact provider build, by checksum.                              |
| **`terraform.tfvars`** | The root's input values. Ours are committed, since they hold choices, never secret values. |

Three blocks change state without changing the cloud. They are the standard refactoring tools:

- `moved` renames an address;
- `import` adopts an existing resource;
- `removed` with `destroy = false` forgets a resource and leaves it in place.

Three safety nets stop a mistake before it reaches the cloud:

- `lifecycle { prevent_destroy = true }` makes OpenTofu refuse any plan that destroys the resource;
- `deletion_protection` and `deletion_policy = "PREVENT"` make Google itself refuse;
- `check` and `precondition` blocks assert facts about the configuration, and a failed one fails
  the plan's check.

## From a pull request to production

Git is the source of truth for production. Every change is a pull request, which shows exactly what
will change. Merging it deploys it, and nobody applies by hand.

```text
pull request ──► checks: validate, lint, test, scan, one plan per root
                  │  plan deletes or unprotects something? ─► needs allow-resource-deletion
                  │  plan upgrades a PostgreSQL major?      ─► needs allow-downtime, during a planned downtime
                  ▼
             approval ──► merge queue ──► master
                                            ▼
deploy:  bootstrap ─► foundation ─┬─► cluster: images, migrations, workloads, health checks
                                  ├─► grafana, github
                                  └─► one job per service root
```

1. **The pull request.** CI validates and tests every root, lints the repository, scans it, and plans
   each root with a read-only identity, the GitHub root only when the merge would apply it. The plans
   appear in the job summaries.
2. **The policy.** Two kinds of plan fail until a maintainer adds a label:
   - a plan that deletes, replaces or forgets a resource, or weakens its protection, needs
     `allow-resource-deletion`, as does a ruleset or deployment pattern the GitHub root would
     prune;
   - a plan that upgrades a database's PostgreSQL major needs `allow-downtime`, and a planned
     downtime of that service in progress.

   A label approves the commit it was added on. A push removes it, so each new commit's plans get
   their own review.

3. **The approval and the merge.** `master` requires one approval, with every review thread
   resolved. It merges through a merge queue, as a single squashed commit. An author cannot approve
   their own pull request, so a maintainer or admin reviews and approves it. An admin may instead
   approve their own pull request with `approve-pr.yaml`, which refuses anyone else's. A bot's pull
   request merges on its own only as a release pin, or as a version update Renovate itself put on
   auto-merge: the Agent App approves and queues it. Renovate puts every minor or patch update on
   auto-merge except OpenTofu's and the Google providers'. Its plans still need a label
   for a deletion or a downtime, so such an update waits for a maintainer. Anything else a bot
   opens, such as a major update, waits for a maintainer's or an admin's review like a person's.
   Repository admins can bypass these rules.
4. **The deploy.** Each merge starts `deploy.yaml`. It applies each root that changed since the last
   successful deploy: bootstrap, then foundation, then the cluster, Grafana and GitHub roots. It
   plans every service root too, which holds only pins. A release pin changes the cluster root,
   which reads them. A deploy run by hand, or by `downtime.yaml`, applies every root.

A daily **drift** check re-plans every root. It fails when the cloud differs from `master`, as after
a change made in the console. It also fails when a repository's setting differs from what the
GitHub root asserts, or when a repository holds a ruleset or deployment pattern the root does not
produce.

## Identities

GitHub Actions gets short-lived Google credentials through **Workload Identity Federation (WIF)**.
No service-account key exists anywhere. The trust conditions live in
[`bootstrap/identity.tf`](../bootstrap/identity.tf).

| Identity           | Used by                                                                                        | Can                                                 |
| ------------------ | ---------------------------------------------------------------------------------------------- | --------------------------------------------------- |
| `infra-plan`       | pull-request plans, the drift check                                                            | read everything a plan needs                        |
| `infra-foundation` | `deploy.yaml` and `recovery.yaml`, on `master`, in the `production` environment                | change everything                                   |
| `infra-downtime`   | `downtime.yaml`, on `master`                                                                   | start and cancel the planned downtime announcements |
| `infra-github`     | the GitHub root's `deploy.yaml` job and `sweep.yaml`, on `master`, in the `github` environment | apply the GitHub root, with no Google Cloud role    |
| `infra-drift`      | the GitHub root's drift check in `drift.yaml`, on `master`                                     | read the GitHub Deploy App keys and the state       |
| `infra-grafana`    | the Grafana root's `deploy.yaml` job, on `master`, in the `grafana` environment                | apply the Grafana root, with no Google Cloud role   |

GitHub issues no OIDC token to pull requests from forks, so outside contributors get no cloud
access.

Human operators are the members of bootstrap's `operator_principals` and foundation's
`database_operator_principals`. They hold three sets of roles:

- **in the management project**, the administration of IAM, Cloud Scheduler, Workflows and the
  management buckets, private audit logs, and the right to add and read versions of every secret;
- **in the workload project**, read access to the cluster, the compute resources, the logs and the
  alert policies;
- **on the cluster**, read access to each service's namespace: its pods and their logs, events and
  workloads, never its Secrets.

The cluster's workload logs stay off Cloud Logging, so operators read them in Grafana, or through
the control plane, with `kubectl` and `gke-gcloud-auth-plugin` installed. Each namespace's Jobs
record its health checks: a `smoke-<hash>` Job per new image, and the `health` CronJob's last runs.

```bash
gcloud container clusters get-credentials a-novel-production --project=a-novel-production-prod --location=europe-west9-a --dns-endpoint
kubectl --namespace=authentication logs deployment/rest
kubectl --namespace=authentication get jobs
```

They have no write access in the workload project or on the cluster. Changes there go through pull
requests.

Foundation's `authentication_maintenance_principals` run Authentication's maintenance operations,
such as granting a role, as a Job copied from the `maintenance` CronJob, as the
[setup runbook](runbooks/setup.md) shows.

## Changes and planned downtime

Most changes deploy without anyone noticing. A workload moves to new pods only once their probes
pass, and a database switches over to its replica, which pauses writes for seconds. A PostgreSQL
major upgrade is different: CloudNativePG stops every instance of the database while `pg_upgrade`
runs.

A major upgrade therefore follows its own path:

- **A planned downtime makes it safe.** An admin schedules one with `downtime.yaml`. Users are warned
  in advance. From its start until it is cleared, the listed services refuse work and leave their
  database alone.
- **The upgrade merges only during that downtime**, with the `allow-downtime` label, and the deploy
  applies it only then.

[Planned downtime](runbooks/downtime.md) and
[PostgreSQL major upgrades](runbooks/database.md#postgresql-major-upgrades) walk through it.

## Fleet tooling

This repository shares its GitHub automation with the other A-Novel repositories. The runbooks name
these pieces:

| Name                          | What it is                                                                                                                                                                    |
| ----------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `approve-pr.yaml`             | Records the approval an author cannot give, run by an admin for their own pull request only: `gh workflow run approve-pr.yaml --repo a-novel/infra -f pull_request="<URL>"`.  |
| `merge-gate`, `epic-freeze`   | Required checks that hold a pull request belonging to a larger change, spread over several pull requests, until that change can land whole. A standalone pull request passes. |
| Dependencies App              | The bot identity Renovate runs as, and the one `pin-release.yaml` opens each release's pull request as.                                                                       |
| Agent App (`anovelbot-agent`) | The bot identity the automation acts as, for example to record an approval or write `DOWNTIME`.                                                                               |

## Why the repository is laid out this way

- **Several roots.** Roots are split by owner and by blast radius. Bootstrap holds the state bucket
  and the CI identities, so a mistake elsewhere cannot lock us out. Foundation holds the long-lived
  shared pieces: the project, the network and the cluster. The cluster root holds every service's
  workloads and database. Each service root holds only that service's release pins and secret
  versions, so a release changes one file.
- **The cluster root reads the other roots.** It reads foundation's applied outputs with
  `terraform_remote_state`, so a new foundation output deploys in its own pull request first. It
  reads each service root's `terraform.tfvars` directly, so a pin deploys in the same merge.
- **Native features first.**
  - Migrations run as a Job the deploy waits on, before the server rolls.
  - A Deployment moves to new pods only once their probes pass.
  - Images are pinned by digest, and copied only after their provenance is verified.
  - Custom code is limited to the health checks the cluster runs, and to the pipeline's rules in
    `.github/scripts`, each with its tests.
