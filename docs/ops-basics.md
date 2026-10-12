# Ops basics

This document explains the ideas behind this repository: how OpenTofu describes production, how a
change travels from a pull request to the cloud, who may do what, and how database changes stay
safe. Read it before the [architecture](architecture.md) and the [runbooks](runbooks/README.md).

## OpenTofu

**OpenTofu** is the open-source fork of Terraform. You declare resources in `.tf` files; OpenTofu
compares them with what exists and makes the API calls that close the gap.

| Term                   | Meaning                                                                                |
| ---------------------- | -------------------------------------------------------------------------------------- |
| **Provider**           | A plugin that talks to an API. Here: `hashicorp/google`, pinned in each `versions.tf`. |
| **Resource**           | One object to manage, such as a VM, a bucket or an IAM grant.                          |
| **Data source**        | A read-only lookup of something managed elsewhere.                                     |
| **Root**               | A directory you run `tofu` in. It has its own state.                                   |
| **Module**             | A reusable directory of resources that roots call. It has no state of its own.         |
| **State**              | A JSON file recording what OpenTofu manages. Ours live in a GCS bucket, one per root.  |
| **Plan**               | The computed difference. Nothing changes until **apply**.                              |
| **Lock file**          | `.terraform.lock.hcl`: the exact provider build, by checksum.                          |
| **`terraform.tfvars`** | The root's input values. Ours are committed: they hold choices, never secret values.   |

Three blocks change state without changing the cloud. They are the standard refactoring tools:

- `moved` renames an address;
- `import` adopts an existing resource;
- `removed` with `destroy = false` forgets a resource and leaves it in place.

Three safety nets stop a mistake before it reaches the cloud:

- `lifecycle { prevent_destroy = true }` makes OpenTofu refuse any plan that destroys the resource;
- `deletion_protection` and `deletion_policy = "PREVENT"` make Google itself refuse;
- `check` and `precondition` blocks assert facts about the configuration.

## From a pull request to production

Git is the source of truth for production. Every change is a pull request, the pull request shows
exactly what will change, and merging it deploys it. Nobody applies by hand.

```text
pull request ──► checks: validate, lint, test, scan, one plan per root
                  │  plan deletes or unprotects something? ─► needs allow-resource-deletion
                  │  plan changes a database host?         ─► needs allow-downtime, during a planned downtime
                  ▼
             approval ──► merge queue ──► master
                                            ▼
deploy:  bootstrap ─► foundation ─► json-keys ──────┬─► rollout of the database hosts
                                    authentication ─┴─► health check
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
   resolved, and merges through a merge queue as a single squashed commit. An author cannot approve
   their own pull request: a repository admin reviews it, then records the approval with
   `approve-pr.yaml`. Renovate's pull requests are approved and queued automatically once their
   checks pass, so a failing plan is what stops one. Repository admins can bypass these rules.
4. **The deploy.** Each merge starts `deploy.yaml`. It applies only the roots changed since the last
   successful deploy, in order: bootstrap, foundation, then the services in parallel. Then two jobs
   run side by side: the database [rollout](#database-hosts-and-planned-downtime) and a production
   health check.

A **drift** check re-plans every root each morning and fails when the cloud differs from `master`,
which catches changes made in the console.

## Identities

GitHub Actions gets short-lived Google credentials through **Workload Identity Federation (WIF)**.
No service-account key exists anywhere. The trust conditions live in
[`bootstrap/main.tf`](../bootstrap/main.tf).

| Identity           | Used by                                                                                               | Can                                                 |
| ------------------ | ----------------------------------------------------------------------------------------------------- | --------------------------------------------------- |
| `infra-plan`       | pull-request plans, the drift check, the scheduled health check                                       | read everything                                     |
| `infra-foundation` | `deploy.yaml`, `roll-database.yaml` and `recovery.yaml`, on `master`, in the `production` environment | change everything                                   |
| `infra-downtime`   | `downtime.yaml`, on `master`                                                                          | start and cancel the planned downtime announcements |

The read-only identity trusts pull requests into `master` and the drift workflow on `master`. GitHub
issues no OIDC token to pull requests from forks, so outside contributors get no cloud access.

Human operators hold two sets of roles:

- **in the management project**, IAM administration (roles, service accounts, workload identity
  pools, project IAM), private audit logs, and the right to add and read versions of every secret;
- **in the production project**, read access, logs, and SSH with administrator rights to the VMs
  through Identity-Aware Proxy.

They have no write access to production resources: changes go through pull requests.

## Database hosts and planned downtime

Most changes deploy without anyone noticing: Cloud Run moves traffic to a new revision only once it
starts. A database host is different. Each service's PostgreSQL runs on one VM, and changing that VM
means restarting it, which makes the database unavailable for a minute or two.

So database host changes follow their own path:

- **A planned downtime makes the restart safe.** An admin schedules one with `downtime.yaml`. Users
  are warned in advance, and from its start the listed services refuse work and leave their
  database alone, until the downtime is cleared.
- **The change merges only during that downtime**, with the `allow-downtime` label.
- **Merging restarts nothing.** It only updates the host's configuration. The deploy's **rollout**
  job then compares each database host with its configuration, and restarts the ones that differ,
  only while their downtime runs. Before each restart, it snapshots the data disk, so the change can
  be undone.
- **The backup repository VMs need no downtime.** The rollout restarts one whenever its configuration
  changed, right after its database host when both did.

[Planned downtime](runbooks/downtime.md) and [Change a database host](runbooks/database.md#change-a-database-host)
walk through it.

## Fleet tooling

This repository shares its GitHub automation with the other `a-novel` repositories. The runbooks
name these pieces:

| Name                          | What it is                                                                                                                                                    |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `a-novel repo update`         | The fleet CLI command that applies a repository's rulesets and shared workflows from the `stack` repository.                                                  |
| `approve-pr.yaml`             | Records an approval an author cannot give: `gh workflow run approve-pr.yaml --repo a-novel/infra -f pull_request=<URL>`. Repository admins only.              |
| `merge-gate`, `epic-freeze`   | Required checks that hold a pull request belonging to a larger, multi-pull-request change until that change can land whole. A standalone pull request passes. |
| Dependencies App              | The bot identity Renovate runs as.                                                                                                                            |
| Agent App (`anovelbot-agent`) | The bot identity automation acts as: it records approvals, writes `DOWNTIME`, and posts comments.                                                             |
| Publish App                   | The bot identity release automation runs as.                                                                                                                  |

## Why the repository is laid out this way

- **Several roots.** Roots are split by owner and by blast radius. Bootstrap holds the state bucket
  and the CI identities, so a mistake elsewhere cannot lock us out. Foundation holds the long-lived
  shared pieces. Each service root holds one service's moving parts, so a release plans a few dozen
  resources instead of hundreds.
- **Roots read foundation's outputs** with `terraform_remote_state` instead of copying values.
- **Modules only for real reuse.** A module needs two callers or one shared invariant.
  `service-runtime` serves three runtimes, one per service and [trust zone](architecture.md#projects),
  and `backup-repository` serves both databases.
- **Native features first.**
  - Migrations run during apply through Cloud Run's `run_execution_token`.
  - Traffic moves only to a revision whose startup probe passes.
  - Images are pinned by digest, and copied only after their provenance is verified.
  - Custom code is limited to the two programs that run on the VMs.

## Local commands

```bash
tofu -chdir=environments/production/foundation init
tofu -chdir=environments/production/foundation plan -lock=false -refresh=false
```

Your account cannot read everything the plan identity can, so use `-refresh=false`: it compares the
code with the state without calling the APIs. That is enough to prove a refactor changes nothing.
