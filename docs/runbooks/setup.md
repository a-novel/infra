# Setup

This runbook covers the GitHub configuration the workflows depend on, and how to rebuild production
from nothing.

## GitHub settings

`a-novel repo update` applies the repository's rulesets:

- **`master`:** every job in `main.yaml` must pass, and so must the fleet's own checks:
  `merge-gate`, `epic-freeze`, `check-dependencies` and `review-gate`. Merges go through a merge
  queue, as signed squash commits.
- **`require-approval`:** one approval, given after the last push, with every review thread
  resolved.

Repository and organization admins can bypass both, and nobody else. Re-run `a-novel repo update`
after renaming or removing a job in `main.yaml`.

Repository variables (Settings → Secrets and variables → Actions):

| Variable                                  | Value (from `tofu -chdir=bootstrap output`)                                                                |
| ----------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `GCP_PLAN_WORKLOAD_IDENTITY_PROVIDER`     | `projects/<management number>/locations/global/workloadIdentityPools/github-actions/providers/github-plan` |
| `GCP_PLAN_SERVICE_ACCOUNT`                | `infra-plan@a-novel-management-prod.iam.gserviceaccount.com`                                               |
| `GCP_DOWNTIME_WORKLOAD_IDENTITY_PROVIDER` | `…/providers/github-downtime`                                                                              |
| `GCP_DOWNTIME_SERVICE_ACCOUNT`            | `infra-downtime@a-novel-management-prod.iam.gserviceaccount.com`                                           |
| `GCP_HEALTH_WORKLOAD_IDENTITY_PROVIDER`   | `…/providers/github-health`                                                                                |
| `GCP_HEALTH_SERVICE_ACCOUNT`              | `infra-health@a-novel-management-prod.iam.gserviceaccount.com`                                             |

`DOWNTIME` holds the planned downtime. Never set it by hand: [downtime.yaml](downtime.md) writes
it with the `anovelbot-agent` App, which needs **Variables: Read and write**, and publishes it on the
`downtime` branch. `HOST_CREDENTIALS_PUBLICATION_ENABLED` and `NATIVE_RESTORE_PUBLICATION_ENABLED`
exist only while a [host tool](host-tools.md#publish-a-version) is being published.

The workflows also read organization variables, which must be visible to this repository: the
Apps' client IDs and logins, `AGENT_KILL_SWITCH`, `DISCORD_REPO_ROLES` and `RELEASE_BOT_LOGIN`.
Without `RELEASE_BOT_LOGIN`, every plan that changes a release image fails. The Apps' private keys
live only in the `governance` environment, which `a-novel repo update` creates and fills from
Bitwarden.

Environment `production`: deployment branches `master` only, no required reviewers.

| Environment variable                        | Value                                                              |
| ------------------------------------------- | ------------------------------------------------------------------ |
| `GCP_FOUNDATION_WORKLOAD_IDENTITY_PROVIDER` | `…/providers/github-foundation`                                    |
| `GCP_FOUNDATION_SERVICE_ACCOUNT`            | `infra-foundation@a-novel-management-prod.iam.gserviceaccount.com` |

Environment `host-artifacts`: the `core` and `owners-infra` teams as required reviewers. Either
approves a host tool publication.

The organization's Renovate (Dependencies) and Agent Apps need access to this repository.

## Organization guardrails

Some rules sit above the projects, where no CI identity holds a role. An organization admin sets
them by hand, once:

- **Organization policies** on the private project keep Cloud Run internal and IAM-checked; see
  [Architecture](../architecture.md#network).
- **A deny policy** keeps the plan identity away from logs and traces. Pull requests can mint
  `infra-plan`, and its Viewer role reads everything else a plan needs.

The deny policy lives in [`policies/infra-plan-data-deny.json`](policies/infra-plan-data-deny.json).
Creating it needs the Deny Admin role on the organization:

```bash
ORG=1031663934757
gcloud iam policies create plan-identity-data --kind=denypolicies \
  --attachment-point="cloudresourcemanager.googleapis.com/organizations/$ORG" \
  --policy-file=docs/runbooks/policies/infra-plan-data-deny.json
```

After a change to the file, run `gcloud iam policies update` with the same arguments.

## Rebuild from nothing

Use this only if the management project is gone: it holds the state, the CI identities and the
secrets. Google never reuses a deleted project's ID, and every bucket name embeds the management
project's number, so a rebuild starts with new names.

1. **Create the management project** under a new ID, and link billing:

   ```bash
   MGMT=<new management project ID>
   gcloud projects create "$MGMT" --organization=1031663934757
   gcloud billing projects link "$MGMT" --billing-account=01BDFE-5B21E7-8393CB
   ```

2. **Rename it everywhere, on a branch.** Replace the old project ID and project number in every
   root's `versions.tf` (the state bucket), `main.tf` and `terraform.tfvars` (project IDs and bucket
   names), and in `.github/workflows/`.
   The next steps run from that branch; it merges in step 6.
3. **Apply bootstrap locally.** This is the only apply a person runs. The state bucket does not
   exist yet, so start with local state, then move it into the bucket:

   ```bash
   cd bootstrap
   printf 'terraform {\n  backend "local" {}\n}\n' > backend_override.tf
   tofu init && tofu apply
   rm backend_override.tf && tofu init -migrate-state
   ```

4. **Let the deploy identity create projects.** Grant it, once, on the organization and the billing
   account:

   ```bash
   gcloud organizations add-iam-policy-binding 1031663934757 --role=roles/resourcemanager.projectCreator \
     --member="serviceAccount:infra-foundation@$MGMT.iam.gserviceaccount.com"
   gcloud billing accounts add-iam-policy-binding 01BDFE-5B21E7-8393CB --role=roles/billing.user \
     --member="serviceAccount:infra-foundation@$MGMT.iam.gserviceaccount.com"
   ```

5. **Configure GitHub** as above, with bootstrap's outputs. CI can plan again from here.
6. **Add every secret value** ([Secrets](secrets.md)), including the pgBackRest TLS certificates.
   Bootstrap created the empty secrets, and new secrets start at version 1: set every pinned version
   in the roots' `terraform.tfvars` to the versions you created, on the same branch. Merge it. Its
   deploy creates the workload projects, the network, the database hosts and the services.
7. **Roll each database host by hand** ([Roll a host by hand](database.md#roll-a-host-by-hand)),
   so it starts with its secrets. Nobody uses the services yet, so no downtime is needed.
8. **SMTP.** Configure the Workspace relay and its DNS records:
   - SPF includes `_spf.google.com`;
   - DKIM is active in Google Admin;
   - DMARC is present.
9. **First administrator.** Grant it with Authentication's `maintenance account-role` command and
   `--role auth:superadmin`. No job in this repository runs it yet.

Workload project IDs that still exist cannot be created again: give the rebuilt ones new IDs in
foundation's `terraform.tfvars` too, or adopt the existing projects with `import` blocks. The deploy
identity has no rights outside the organization's projects.
