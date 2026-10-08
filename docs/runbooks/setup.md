# Setup

## GitHub settings

`a-novel repo update` applies the `master` ruleset. Its required checks are every job in `main.yaml`
plus `merge-gate` and `epic-freeze`. Re-run it after any job rename.

Repository variables (Settings → Secrets and variables → Actions):

| Variable                              | Value (from `tofu -chdir=bootstrap output`)                                                                |
| ------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `GCP_PLAN_WORKLOAD_IDENTITY_PROVIDER` | `projects/<management number>/locations/global/workloadIdentityPools/github-actions/providers/github-plan` |
| `GCP_PLAN_SERVICE_ACCOUNT`            | `infra-plan@a-novel-management-prod.iam.gserviceaccount.com`                                               |

`DOWNTIME` holds the planned downtime window. Never set it by hand: [downtime.yaml](downtime.md)
writes it with the `anovelbot-agent` App, which needs **Variables: Read and write**.

Environment `production`: deployment branches `master` only, no required reviewers.

| Environment variable                        | Value                                                              |
| ------------------------------------------- | ------------------------------------------------------------------ |
| `GCP_FOUNDATION_WORKLOAD_IDENTITY_PROVIDER` | `…/providers/github-foundation`                                    |
| `GCP_FOUNDATION_SERVICE_ACCOUNT`            | `infra-foundation@a-novel-management-prod.iam.gserviceaccount.com` |

The organization's Renovate app needs access to this repository.

## Rebuild from nothing

Use this only if the management project is gone. Everything else is recreated by deploys.

1. **Create the management project** and link billing:

   ```bash
   gcloud projects create a-novel-management-prod --organization=1031663934757
   gcloud billing projects link a-novel-management-prod --billing-account=01BDFE-5B21E7-8393CB
   ```

2. **Apply bootstrap locally.** This is the only manual apply. The state bucket does not exist yet,
   so start with local state and then move it into the bucket:

   ```bash
   cd bootstrap
   printf 'terraform {\n  backend "local" {}\n}\n' > backend_override.tf
   tofu init && tofu apply
   rm backend_override.tf && tofu init -migrate-state
   ```

   If the project number changed, update the bucket names in every `versions.tf` and
   `terraform.tfvars` first.

3. **Let the deploy identity create projects.** Grant it, once, on the organization and the billing
   account:

   ```bash
   gcloud organizations add-iam-policy-binding 1031663934757 --role=roles/resourcemanager.projectCreator \
     --member="serviceAccount:infra-foundation@a-novel-management-prod.iam.gserviceaccount.com"
   gcloud billing accounts add-iam-policy-binding 01BDFE-5B21E7-8393CB --role=roles/billing.user \
     --member="serviceAccount:infra-foundation@a-novel-management-prod.iam.gserviceaccount.com"
   ```

4. **Configure GitHub** as above, then run `deploy.yaml`. It creates the projects, network,
   database hosts and services.
5. **Add every secret value.** See [Secrets](secrets.md); this includes the pgBackRest TLS
   certificates. Then roll each database host.
6. **SMTP.** Configure the Workspace relay and its DNS records:
   - SPF includes `_spf.google.com`;
   - DKIM is active in Google Admin;
   - DMARC is present.
7. **First administrator.** Run Authentication's `maintenance account-role` job with
   `--role auth:superadmin`. Moving this into the service root is tracked in
   [#243](https://github.com/a-novel/infra/issues/243).

The deploy identity has no rights outside the organization's projects. Rebuilding the workload
projects alone is just steps 4 and 5.
