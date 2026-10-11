# Setup

This runbook covers the GitHub configuration the workflows depend on, and how to rebuild production
from nothing.

## GitHub settings

`a-novel repo update` applies the repository's rulesets:

- **`master`:** every job in `main.yaml`, plus `merge-gate` and `epic-freeze`, must pass. Merges go
  through a merge queue, as signed squash commits.
- **`require-approval`:** one approval, given after the last push, with every review thread
  resolved. The Dependencies, Publish and Agent Apps are exempt.

Repository and organization admins can bypass both. Re-run `a-novel repo update` after renaming or
removing a job in `main.yaml`.

Repository variables (Settings → Secrets and variables → Actions):

| Variable                              | Value (from `tofu -chdir=bootstrap output`)                                                                |
| ------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `GCP_PLAN_WORKLOAD_IDENTITY_PROVIDER` | `projects/<management number>/locations/global/workloadIdentityPools/github-actions/providers/github-plan` |
| `GCP_PLAN_SERVICE_ACCOUNT`            | `infra-plan@a-novel-management-prod.iam.gserviceaccount.com`                                               |

`DOWNTIME` holds the planned downtime. Never set it by hand: [downtime.yaml](downtime.md) writes
it with the `anovelbot-agent` App, which needs **Variables: Read and write**, and publishes it on the
`downtime` branch. `HOST_CREDENTIALS_PUBLICATION_ENABLED` and `NATIVE_RESTORE_PUBLICATION_ENABLED`
exist only while a [host tool](host-tools.md#publish-a-version) is being published.

The workflows also read the organization's App credentials, which must be visible to this
repository: `AGENT_BOT_CLIENT_ID`, `AGENT_KILL_SWITCH`, `DEPENDENCY_BOT_CLIENT_ID`,
`DEPENDENCY_BOT_LOGIN` and `DEPENDABOT_SECURITY_LOGIN` (variables), and `AGENT_BOT_PRIVATE_KEY` and
`DEPENDENCY_BOT_PRIVATE_KEY` (secrets).

Environment `production`: deployment branches `master` only, no required reviewers.

| Environment variable                        | Value                                                              |
| ------------------------------------------- | ------------------------------------------------------------------ |
| `GCP_FOUNDATION_WORKLOAD_IDENTITY_PROVIDER` | `…/providers/github-foundation`                                    |
| `GCP_FOUNDATION_SERVICE_ACCOUNT`            | `infra-foundation@a-novel-management-prod.iam.gserviceaccount.com` |

Environment `host-artifacts`: a required reviewer, who approves each host tool publication.

The organization's Renovate (Dependencies) and Agent Apps need access to this repository.

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
   root's `versions.tf` (the state bucket) and `terraform.tfvars` (project IDs and bucket names).
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
