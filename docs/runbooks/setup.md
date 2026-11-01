# Setup

This runbook is about the GitHub and organization settings the workflows depend on, and about
rebuilding production from nothing.

## GitHub settings

The GitHub root, `environments/production/github`, applies the repository's rulesets:

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
| `GCP_DRIFT_WORKLOAD_IDENTITY_PROVIDER`    | `…/providers/github-drift`                                                                                 |
| `GCP_DRIFT_SERVICE_ACCOUNT`               | `infra-drift@a-novel-management-prod.iam.gserviceaccount.com`                                              |

`DOWNTIME` holds the planned downtime. Never set it by hand. [downtime.yaml](downtime.md) writes it
with the `anovelbot-agent` App, which needs **Variables: Read and write**, and publishes it on the
`downtime` branch.

The workflows also read organization variables, which must be visible to this repository: the
Apps' client IDs and logins, `AGENT_KILL_SWITCH`, `DISCORD_REPO_ROLES` and `RELEASE_BOT_LOGIN`.
Without `RELEASE_BOT_LOGIN`, every plan that changes a release image fails. The Apps' private keys
live only in the `governance` environment, which the GitHub root creates and its secret sync fills
from Secret Manager. The deploys post to Discord through the `DEPLOY_WEBHOOK` secret, and skip their
posts without it.

Environment `production` allows the `master` branch only, with no required reviewers:

| Environment variable                        | Value                                                              |
| ------------------------------------------- | ------------------------------------------------------------------ |
| `GCP_FOUNDATION_WORKLOAD_IDENTITY_PROVIDER` | `…/providers/github-foundation`                                    |
| `GCP_FOUNDATION_SERVICE_ACCOUNT`            | `infra-foundation@a-novel-management-prod.iam.gserviceaccount.com` |

Environment `github` allows the `master` branch only, with no required reviewers. The GitHub root's
deploys and its sweep apply from it, apart from Google Cloud's production:

| Environment variable                    | Value                                                          |
| --------------------------------------- | -------------------------------------------------------------- |
| `GCP_GITHUB_WORKLOAD_IDENTITY_PROVIDER` | `…/providers/github-github`                                    |
| `GCP_GITHUB_SERVICE_ACCOUNT`            | `infra-github@a-novel-management-prod.iam.gserviceaccount.com` |

Environment `grafana` allows the `master` branch only, with no required reviewers. The Grafana
root's deploys apply from it, apart from Google Cloud's production:

| Environment variable                     | Value                                                           |
| ---------------------------------------- | --------------------------------------------------------------- |
| `GCP_GRAFANA_WORKLOAD_IDENTITY_PROVIDER` | `…/providers/github-grafana`                                    |
| `GCP_GRAFANA_SERVICE_ACCOUNT`            | `infra-grafana@a-novel-management-prod.iam.gserviceaccount.com` |

The organization's Renovate (Dependencies) and Agent Apps need access to this repository.

## Organization guardrails

Some rules sit above the projects, where no CI identity holds a role. An organization admin sets
them by hand, once:

- **A deny policy** keeps the plan identity away from logs and traces. Pull requests can mint
  `infra-plan`, and its Viewer role reads everything else a plan needs.
- **The access policy** holds the service perimeter, which foundation manages. The deploy identity
  edits the policy and the plan identity reads it. Both also read the organization's access
  policies, which Artifact Registry checks whenever its VPC Service Controls setting is set or
  read.

The deny policy lives in [`policies/infra-plan-data-deny.json`](policies/infra-plan-data-deny.json).
Creating it needs the Deny Admin role on the organization:

```bash
gcloud iam policies create plan-identity-data --kind=denypolicies \
  --attachment-point="cloudresourcemanager.googleapis.com/organizations/1031663934757" \
  --policy-file=docs/runbooks/policies/infra-plan-data-deny.json
```

After a change to the file, run `gcloud iam policies update` with the same arguments.

Creating the access policy and granting on it needs Access Context Manager Admin on the
organization. Foundation's `access_policy_id` holds the number the list prints:

```bash
gcloud access-context-manager policies create --organization=1031663934757 --title=agora
POLICY="$(gcloud access-context-manager policies list --organization=1031663934757 --format='value(name)')"
gcloud access-context-manager policies add-iam-policy-binding "$POLICY" \
  --role=roles/accesscontextmanager.policyEditor \
  --member="serviceAccount:infra-foundation@a-novel-management-prod.iam.gserviceaccount.com"
gcloud access-context-manager policies add-iam-policy-binding "$POLICY" \
  --role=roles/accesscontextmanager.policyReader \
  --member="serviceAccount:infra-plan@a-novel-management-prod.iam.gserviceaccount.com"
```

Artifact Registry lists the organization's access policies whenever its VPC Service Controls
setting is set or read, so the deploy and plan identities read them on the organization:

```bash
for identity in infra-foundation infra-plan; do
  gcloud organizations add-iam-policy-binding 1031663934757 \
    --role=roles/accesscontextmanager.policyReader \
    --member="serviceAccount:$identity@a-novel-management-prod.iam.gserviceaccount.com" \
    --condition=None
done
```

## Rebuild from nothing

Use this only if the management project is gone, since it holds the state, the CI identities, the
secrets and the backups, so the databases start empty. Google never reuses a deleted project's ID,
and every bucket name embeds the management project's number, so a rebuild starts with new names.

1. **Create the management project** under a new ID, and link billing:

   ```bash
   MGMT="<new management project ID>"
   gcloud projects create "$MGMT" --organization=1031663934757
   gcloud billing projects link "$MGMT" --billing-account=01BDFE-5B21E7-8393CB
   gcloud projects describe "$MGMT" --format='value(projectNumber)'
   ```

2. **Rename it everywhere, on a branch.** Replace the old project ID and number with the new ones in
   every file this lists. The project IDs and bucket names sit in each root's `versions.tf`,
   `main.tf` and `terraform.tfvars`, and in the workflows. If the workload project still exists,
   give the rebuilt one a new ID in foundation's and bootstrap's `terraform.tfvars` too, or adopt it
   with `import` blocks. The deploy identity has no rights outside the organization's projects.

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
   gcloud organizations add-iam-policy-binding 1031663934757 --role=roles/resourcemanager.projectCreator \
     --member="$DEPLOYER"
   gcloud billing accounts add-iam-policy-binding 01BDFE-5B21E7-8393CB --role=roles/billing.user \
     --member="$DEPLOYER"
   ```

   Then grant the new deploy and plan identities on the access policy, as
   [Organization guardrails](#organization-guardrails) shows, with the new project ID.

5. **Configure GitHub** [as above](#github-settings), with the values
   `tofu -chdir=bootstrap output` prints. CI can plan again from here.
6. **Add every secret value**, as [Secrets](secrets.md) describes. Bootstrap created the empty
   secrets, and new secrets start at version 1. On the same branch, set every pinned version in the
   roots' `terraform.tfvars` to the versions you created, and the cluster root's `custom_resources`
   to `false`, since a fresh cluster lacks the add-ons' kinds. Merge it. Its deploy creates the
   workload project, the network, the cluster and its add-ons.
7. **Let OpenAI and the SMTP relay admit the NAT address**, which foundation's
   `cluster_nat_address` output gives:
   - OpenAI's project allows that address alone;
   - the [relay rule](secrets.md#smtp-google-workspace-relay) admits it;
   - SPF includes `_spf.google.com`;
   - DKIM is active in Google Admin;
   - DMARC is present.
8. **Turn the custom resources on.** Set the cluster root's `custom_resources` to `true` in a pull
   request, and merge it. Its deploy creates every database, empty, and the services, and waits on
   their smoke checks and GenAI's call to OpenAI.
9. **Point each platform's host at its address.** Foundation's `platform_edges` output lists the DNS
   records each host needs, the certificate's authorization first, then the address. Add them in
   Squarespace's DNS for `storyverse.fr`:

   ```bash
   tofu -chdir=environments/production/foundation init
   tofu -chdir=environments/production/foundation output -json platform_edges | jq '.[].dns_records'
   ```

10. **Grant the first administrator** by running Authentication's maintenance operation
    `account-role`. It emails the address a registration link, and the account it creates gets the
    role. Only the `authentication_maintenance_principals` may run it: they copy the suspended
    `maintenance` CronJob into a Job whose arguments name the operation. Admission refuses any other
    change to its template. With `kubectl`, `gke-gcloud-auth-plugin` and `jq` installed:

    ```bash
    gcloud container clusters get-credentials a-novel-production --project=a-novel-production-prod --location=europe-west9-a --dns-endpoint
    kubectl --namespace=authentication create job --from=cronjob/maintenance first-admin --dry-run=client -o json |
      jq '.spec.template.spec.containers[0].args = ["account-role", "--email=<address>", "--role=auth:superadmin"]' |
      kubectl --namespace=authentication create -f -
    kubectl --namespace=authentication logs --follow --pod-running-timeout=2m job/first-admin
    ```

    The log ends with `account-role completed for <address> with outcome …`. A Job's name serves
    once, so give a second run another name. A failed Job is not retried: read its log, then run it
    again. Running the operation again converges on the same role.
