# Ops basics

This document is about the ideas behind this repository, which every runbook relies on. Read it
before the [architecture](architecture.md) and the [runbooks](runbooks/README.md).

## OpenTofu

**OpenTofu** is the open-source fork of Terraform. You declare resources in `.tf` files. OpenTofu
compares them with what exists, and makes the API calls that close the gap.

| Term                   | Meaning                                                                                    |
| ---------------------- | ------------------------------------------------------------------------------------------ |
| **Provider**           | A plugin that talks to an API, pinned in each root's `versions.tf`.                        |
| **Resource**           | One object to manage, such as a VM, a bucket or an IAM grant.                              |
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
                  │  plan changes a database host?         ─► needs allow-downtime, during a planned downtime
                  ▼
             approval ──► merge queue ──► master
                                            ▼
deploy:  bootstrap ─► foundation ─► one job per service ─┬─► rollout of the database hosts
                                                         └─► health check
```

1. **The pull request.** CI validates and tests every root, lints the repository, scans it, and plans
   each root with a read-only identity. The plans appear in the job summaries.
2. **The policy.** Two kinds of plan fail until a maintainer adds a label:
   - a plan that deletes, replaces or forgets a resource, or weakens its protection, needs
     `allow-resource-deletion`;
   - a plan that changes a database host needs `allow-downtime`, and a planned downtime of that
     service in progress.

   A label approves the commit it was added on. A push removes it, so each new commit's plans get
   their own review.

3. **The approval and the merge.** `master` requires one approval, with every review thread
   resolved. It merges through a merge queue, as a single squashed commit. An author cannot approve
   their own pull request, so a maintainer or admin reviews and approves it. An admin may instead
   approve their own pull request with `approve-pr.yaml`, which refuses anyone else's. A bot's pull
   request merges on its own only as a release pin, or as a version update Renovate itself put on
   auto-merge: the Agent App approves and queues it. Anything else a bot opens, such as a provider,
   OpenTofu or major update, waits for a maintainer's or an admin's review like a person's.
   Repository admins can bypass these rules.
4. **The deploy.** Each merge starts `deploy.yaml`. It applies bootstrap and foundation when they
   changed since the last successful deploy. Then it applies every service root in parallel, so the
   services always run the current planned downtime. Once a root's Cloud Run services serve a new
   release, its job records the release's `production` deploy in Sentry. Two jobs then run side by
   side: the database [rollout](#database-hosts-and-planned-downtime) and a production health check.

A daily **drift** check re-plans every root. It fails when the cloud differs from `master`, as after
a change made in the console.

## Identities

GitHub Actions gets short-lived Google credentials through **Workload Identity Federation (WIF)**.
No service-account key exists anywhere. The trust conditions live in
[`bootstrap/identity.tf`](../bootstrap/identity.tf).

| Identity           | Used by                                                                                               | Can                                                 |
| ------------------ | ----------------------------------------------------------------------------------------------------- | --------------------------------------------------- |
| `infra-plan`       | pull-request plans, the drift check                                                                   | read everything a plan needs                        |
| `infra-foundation` | `deploy.yaml`, `roll-database.yaml` and `recovery.yaml`, on `master`, in the `production` environment | change everything                                   |
| `infra-downtime`   | `downtime.yaml`, on `master`                                                                          | start and cancel the planned downtime announcements |
| `infra-health`     | the scheduled health check in `drift.yaml`, on `master`                                               | call Authentication's REST API, find Studio's URL   |

GitHub issues no OIDC token to pull requests from forks, so outside contributors get no cloud
access.

Human operators are the members of bootstrap's `operator_principals` and foundation's
`database_operator_principals`. They hold two sets of roles:

- **in the management project**, the administration of IAM, Cloud Scheduler, Workflows and the
  management buckets, private audit logs, and the right to add and read versions of every secret;
- **in the production project**, read access, logs, and SSH with administrator rights to the VMs
  through Identity-Aware Proxy.

They have no write access in the workload projects. Changes there go through pull requests, and
host restarts through the workflows.

## Database hosts and planned downtime

Most changes deploy without anyone noticing, since Cloud Run moves traffic to a new revision only
once it starts. A database host is different. Each service's PostgreSQL runs on one VM, and changing
that VM means restarting it, which makes the database unavailable for a minute or two.

Database host changes therefore follow their own path:

- **A planned downtime makes the restart safe.** An admin schedules one with `downtime.yaml`. Users
  are warned in advance. From its start until it is cleared, the listed services refuse work and
  leave their database alone.
- **The change merges only during that downtime**, with the `allow-downtime` label.
- **Merging restarts nothing.** It only updates the host's configuration. The deploy's **rollout**
  job then restarts each database host that differs from its configuration, and only while its
  downtime runs. It snapshots the data disk first, which keeps the data as it stood before.
- **The backup repository VMs need no downtime.** The rollout restarts one whenever its
  configuration changed, and after each restart of its database host.

[Planned downtime](runbooks/downtime.md) and
[Change a database host](runbooks/database.md#change-a-database-host) walk through it.

## Fleet tooling

This repository shares its GitHub automation with the other A-Novel repositories. The runbooks name
these pieces:

| Name                          | What it is                                                                                                                                                                    |
| ----------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `a-novel repo update`         | The stack CLI command that applies a repository's settings, rulesets and managed workflows.                                                                                   |
| `approve-pr.yaml`             | Records the approval an author cannot give, run by an admin for their own pull request only: `gh workflow run approve-pr.yaml --repo a-novel/infra -f pull_request="<URL>"`.  |
| `merge-gate`, `epic-freeze`   | Required checks that hold a pull request belonging to a larger change, spread over several pull requests, until that change can land whole. A standalone pull request passes. |
| Dependencies App              | The bot identity Renovate runs as, and the one `pin-release.yaml` opens each release's pull request as.                                                                       |
| Agent App (`anovelbot-agent`) | The bot identity the automation acts as, for example to record an approval or write `DOWNTIME`.                                                                               |

## Why the repository is laid out this way

- **Several roots.** Roots are split by owner and by blast radius. Bootstrap holds the state bucket
  and the CI identities, so a mistake elsewhere cannot lock us out. Foundation holds the long-lived
  shared pieces. Each service root holds one service's moving parts, so a release plans a few dozen
  resources instead of hundreds.
- **Service roots read foundation's applied outputs** with `terraform_remote_state`. A new
  foundation output therefore deploys in its own pull request, before a service root reads it.
- **Native features first.**
  - Migrations run during apply through Cloud Run's `run_execution_token`.
  - Traffic moves only to a revision whose startup probe passes.
  - Images are pinned by digest, and copied only after their provenance is verified.
  - Custom code is limited to the two programs that run on the VMs, and to the pipeline's rules in
    `.github/scripts`, each with its tests.
