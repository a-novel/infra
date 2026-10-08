# Ops basics

What you need to know to read and change this repository.

## Infrastructure as code

**OpenTofu** is the open-source fork of Terraform. You declare resources in `.tf` files;
OpenTofu computes the difference with what exists and makes the calls.

| Term                   | Meaning                                                                               |
| ---------------------- | ------------------------------------------------------------------------------------- |
| **Provider**           | Plugin that talks to an API. Here: `hashicorp/google`, pinned in each `versions.tf`.  |
| **Resource**           | One object to manage, such as a VM, a bucket or an IAM grant.                         |
| **Data source**        | A read-only lookup of something managed elsewhere.                                    |
| **Root**               | A directory you run `tofu` in. It has its own state.                                  |
| **Module**             | A reusable directory of resources that roots call. It has no state of its own.        |
| **State**              | A JSON file recording what OpenTofu manages. Ours live in a GCS bucket, one per root. |
| **Plan**               | The computed difference. Nothing changes until **apply**.                             |
| **Lock file**          | `.terraform.lock.hcl`: the exact provider build, by checksum.                         |
| **`terraform.tfvars`** | The root's input values. Ours are committed: they hold choices, never secret values.  |

Three blocks change state without changing the cloud, and are standard refactoring tools:

- `moved` renames an address.
- `import` adopts an existing resource.
- `removed` with `destroy = false` forgets one.

### Safety nets

- `lifecycle { prevent_destroy = true }` makes OpenTofu refuse any plan that destroys the resource.
- `deletion_protection` and `deletion_policy = "PREVENT"` make Google itself refuse.
- `check` and `precondition` blocks assert facts about the configuration.

## GitOps

Git is the source of truth for production.

- The pull request **is** the review: its plan shows exactly what will change.
- The merge **is** the deployment.
- A daily **drift** check re-plans every root and fails if the cloud differs from `master`. That
  catches manual console edits.

Destructive changes are opt-in: a maintainer adds the `allow-resource-deletion` label. The policy
lives in [`.github/actions/tofu/policy.jq`](../.github/actions/tofu/policy.jq) and is about ten
lines long.

## Identities

GitHub Actions gets short-lived Google credentials through **Workload Identity Federation (WIF)**.
No service-account key exists anywhere. The trust conditions live in
[`bootstrap/main.tf`](../bootstrap/main.tf):

| Identity           | Used by                                                                                           | Can               |
| ------------------ | ------------------------------------------------------------------------------------------------- | ----------------- |
| `infra-plan`       | pull-request plans, drift, health checks                                                          | read everything   |
| `infra-foundation` | `deploy.yaml`, `roll-database.yaml`, `recovery.yaml` on `master`, in the `production` environment | change everything |

GitHub never issues OIDC tokens to pull requests from forks, so outside contributors get no cloud
access. Humans get narrow roles: secret versions, IAP SSH to database hosts, read access.

## Why this layout

- **Several roots, not one.** Roots are split by owner and by blast radius. Bootstrap holds the state
  bucket and CI identities, so a mistake elsewhere cannot lock us out. Foundation holds the
  long-lived shared pieces. Each service root holds one service's moving parts, so a release plans
  a few dozen resources, not five hundred.
- **Roots read foundation's outputs** with `terraform_remote_state` rather than copying values.
- **Modules only for real reuse.** A module needs two callers or one shared invariant.
  `service-runtime` serves three service zones, and `backup-repository` serves both databases.
- **Everything else is native.**
  - Migrations run during apply through Cloud Run's `run_execution_token`.
  - Traffic moves only to a revision whose startup probe passes.
  - Images are pinned by digest and copied with their provenance verified.
  - Custom code is limited to the two programs that run on VMs.
- **Database hosts never restart on merge.** Their instance group uses an `OPPORTUNISTIC` update
  policy. Rolling a host is a deliberate step in [Database hosts](runbooks/database.md).

## Local commands

```bash
tofu -chdir=environments/production/foundation init
tofu -chdir=environments/production/foundation plan -lock=false -refresh=false
```

Your account cannot read everything the plan identity can, so use `-refresh=false`. It compares
code with state without calling the APIs. That is enough to prove a refactor changes nothing.
