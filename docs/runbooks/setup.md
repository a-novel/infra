# Setup

This runbook is about the GitHub and organization settings the workflows depend on, and about
rebuilding production from nothing.

## GitHub settings

`a-novel repo update` applies the repository's rulesets:

- **`master`:** every job in `main.yaml` must pass, and so must the fleet's own checks:
  `merge-gate`, `epic-freeze`, `check-dependencies` and `review-gate`. Merges go through a merge
  queue, as signed squash commits.
- **`require-approval`:** one approval, given after the last push, with every review thread
  resolved.

Repository and organization admins can bypass both, and nobody else. Renaming or removing a job in
`main.yaml` needs [one more step](deployments.md#other-cases).

Set the repository variables under **Settings → Secrets and variables → Actions**:

| Variable                                  | Value (from `tofu -chdir=bootstrap output`)                                                                |
| ----------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `GCP_PLAN_WORKLOAD_IDENTITY_PROVIDER`     | `projects/<management number>/locations/global/workloadIdentityPools/github-actions/providers/github-plan` |
| `GCP_PLAN_SERVICE_ACCOUNT`                | `infra-plan@a-novel-management-prod.iam.gserviceaccount.com`                                               |
| `GCP_DOWNTIME_WORKLOAD_IDENTITY_PROVIDER` | `…/providers/github-downtime`                                                                              |
| `GCP_DOWNTIME_SERVICE_ACCOUNT`            | `infra-downtime@a-novel-management-prod.iam.gserviceaccount.com`                                           |
| `GCP_HEALTH_WORKLOAD_IDENTITY_PROVIDER`   | `…/providers/github-health`                                                                                |
| `GCP_HEALTH_SERVICE_ACCOUNT`              | `infra-health@a-novel-management-prod.iam.gserviceaccount.com`                                             |

`DOWNTIME` holds the planned downtime. Never set it by hand. [downtime.yaml](downtime.md) writes it
with the `anovelbot-agent` App, which needs **Variables: Read and write**, and publishes it on the
`downtime` branch. `HOST_CREDENTIALS_PUBLICATION_ENABLED` and `NATIVE_RESTORE_PUBLICATION_ENABLED`
exist only while a [host tool](host-tools.md#publish-a-version) is being published.

The workflows also read organization variables, which must be visible to this repository: the
Apps' client IDs and logins, `AGENT_KILL_SWITCH`, `DISCORD_REPO_ROLES` and `RELEASE_BOT_LOGIN`.
Without `RELEASE_BOT_LOGIN`, every plan that changes a release image fails. The Apps' private keys
live only in the `governance` environment, which `a-novel repo update` creates and fills from
Bitwarden. The deploys and rollouts post to Discord through the `DEPLOY_WEBHOOK` secret, and skip
their posts without it.

Environment `production` allows the `master` branch only, with no required reviewers:

| Environment variable                        | Value                                                              |
| ------------------------------------------- | ------------------------------------------------------------------ |
| `GCP_FOUNDATION_WORKLOAD_IDENTITY_PROVIDER` | `…/providers/github-foundation`                                    |
| `GCP_FOUNDATION_SERVICE_ACCOUNT`            | `infra-foundation@a-novel-management-prod.iam.gserviceaccount.com` |

Environment `host-artifacts` has the `core` and `owners-infra` teams as required reviewers. Either
one approves a host tool publication.

The organization's Renovate (Dependencies) and Agent Apps need access to this repository.

## Organization guardrails

Some rules sit above the projects, where no CI identity holds a role. An organization admin sets
them by hand, once:

- **Organization policies** on the private project keep Cloud Run internal and IAM-checked, as
  [Architecture](../architecture.md#network) describes.
- **A deny policy** keeps the plan identity away from logs and traces. Pull requests can mint
  `infra-plan`, and its Viewer role reads everything else a plan needs.

The deny policy lives in [`policies/infra-plan-data-deny.json`](policies/infra-plan-data-deny.json).
Creating it needs the Deny Admin role on the organization:

```bash
gcloud iam policies create plan-identity-data --kind=denypolicies \
  --attachment-point="cloudresourcemanager.googleapis.com/organizations/$ORG" \
  --policy-file=docs/runbooks/policies/infra-plan-data-deny.json
```

After a change to the file, run `gcloud iam policies update` with the same arguments.

## Rebuild from nothing

Use this only if the management project is gone, since it holds the state, the CI identities and the
secrets. Google never reuses a deleted project's ID, and every bucket name embeds the management
project's number, so a rebuild starts with new names.

1. **Create the management project** under a new ID, and link billing:

   ```bash
   MGMT="<new management project ID>"
   gcloud projects create "$MGMT" --organization="$ORG"
   gcloud billing projects link "$MGMT" --billing-account="$BILLING"
   gcloud projects describe "$MGMT" --format='value(projectNumber)'
   ```

2. **Rename it everywhere, on a branch.** Replace the old project ID and number with the new ones in
   every file this lists. The project IDs and bucket names sit in each root's `versions.tf`,
   `main.tf` and `terraform.tfvars`, and in the workflows. If the workload projects still exist,
   give the rebuilt ones new IDs in foundation's `terraform.tfvars` too, or adopt them with `import`
   blocks. The deploy identity has no rights outside the organization's projects.

   ```bash
   grep -rlE 'a-novel-management-prod|232403541574' --exclude-dir=.git .
   ```

   The next steps run from that branch, which merges in step 6.

3. **Apply bootstrap locally.** This is the only apply a person runs. The state bucket does not
   exist yet, so start with local state, then move it into the bucket:

   ```bash
   printf 'terraform {\n  backend "local" {}\n}\n' > bootstrap/backend_override.tf
   tofu -chdir=bootstrap init
   tofu -chdir=bootstrap apply
   rm bootstrap/backend_override.tf
   tofu -chdir=bootstrap init -migrate-state
   ```

4. **Let the deploy identity create projects.** Grant it, once, on the organization and the billing
   account:

   ```bash
   DEPLOYER="serviceAccount:infra-foundation@$MGMT.iam.gserviceaccount.com"
   gcloud organizations add-iam-policy-binding "$ORG" --role=roles/resourcemanager.projectCreator \
     --member="$DEPLOYER"
   gcloud billing accounts add-iam-policy-binding "$BILLING" --role=roles/billing.user \
     --member="$DEPLOYER"
   ```

5. **Configure GitHub** [as above](#github-settings), with the values
   `tofu -chdir=bootstrap output` prints. CI can plan again from here.
6. **Add every secret value**, as [Secrets](secrets.md) describes, including the pgBackRest TLS
   certificates. Bootstrap created the empty secrets, and new secrets start at version 1. Set every
   pinned version in the roots' `terraform.tfvars` to the versions you created, on the same branch.
   Merge it. Its deploy creates the workload projects, the network, the database hosts and the
   services.
7. **Roll each database host by hand**, as [Roll a host by hand](database.md#roll-a-host-by-hand)
   describes, so it starts with its secrets. Nobody uses the services yet, so no downtime is needed.
8. **Configure SMTP**, the Workspace relay and its DNS records:
   - SPF includes `_spf.google.com`;
   - DKIM is active in Google Admin;
   - DMARC is present.
9. **Grant the first administrator** with Authentication's `maintenance account-role` command and
   `--role auth:superadmin`. No job in this repository runs it yet.
