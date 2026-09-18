# Service-project onboarding boundary

Service projects are opt-in project shells. Production still runs in the existing workload project.
Keep `service_projects = {}` until a separately reviewed onboarding change supplies the exact project
IDs, temporary provisioning permissions, configuration publication, verification, and access-removal
commands. Merging the project module is not authorization to create a project or move a workload.

## Review the configuration

The protected foundation input accepts a service-name-to-project-ID map. For example, these synthetic
test values create two project shells:

```hcl
service_projects = {
  json-keys      = "agora-json-keys-test"
  authentication = "agora-authentication-test"
}
```

Use one entry per independently operated service and environment, not per image, job, or revision.
Project IDs must differ from each other, management, and the existing workload project. A production
service project requires the same organization/folder parent as the foundation. Recovery input must
omit the map or set it to `{}`; the root rejects a nonempty map in recovery mode.

The existing protected foundation workflow already passes the complete private input to OpenTofu.
Its plan/apply custody and serialization remain unchanged. The initial `foundation-setup configure`
helper still generates the legacy input shape: service onboarding must extend that publication path
before activation, so rerunning configuration cannot silently discard the selected map.

## What the plan will own

- The [project module](../../modules/workload-project/README.md) creates protected project shells,
  enables APIs, deprivileges default accounts, grants foundation maintenance and plan inspection,
  and bounds default logs.
- Foundation enables the existing workload project as a Shared VPC host and attaches each shell.
  It owns the VPC, subnet, routes, firewall rules, and DNS. Both host and attachment have deletion
  guards. No Network User grant or Google service-agent subnet grant is added.
- The existing production budget includes the new project numbers. Its amount, thresholds, and
  notification channels remain unchanged. No paid runtime or network appliance is provisioned.

An attachment is not a network-security proof. Service-specific subnet permissions, firewall and
egress policy, Cloud Run internal routing, and application authentication must be reviewed before
deploying a service. Current deployers receive no new-project grants. Management secrets, backups,
receipts, and state retain their existing owners.

## First activation prerequisites

The onboarding PR must record the exact operator commands and successful sanitized results for:

1. Project Creator and billing-link authority for the protected foundation identity, plus temporary
   Shared VPC administration at the appropriate parent. All projects must belong to the same
   organization. Inherited default-account and service-account-key policies must be enforced.
2. Publishing and preserving the selected map in protected foundation inputs while keeping recovery
   inputs empty. Do not replace a complete protected configuration with the example above.
3. The existing separate reviewed plan and apply runs. Inspect project creation, API/IAM changes,
   Shared VPC attachment, and budget scope; stop for workload changes or legacy resource replacement.
4. Verifying exact project parents/billing, no default VPC, enabled APIs, zero user-managed keys,
   effective organization policies, deprivileged default accounts, host attachment, and budget scope.
5. Removing temporary Owner/project-creation/billing/Shared VPC grants and verifying that the
   standing maintenance identity can still produce a zero-change plan.

Use the existing foundation workflow; do not apply this module from a local terminal. After an
interruption, inspect actual project ownership and the saved state before retrying. Do not import,
delete, or change a globally unique project ID to work around a failed creation. Keep the project
and attachment guards in place during reconciliation.

Moving the first service requires a separate ownership-transfer plan covering its identities, state,
registry, runtime, database, secrets, backups, retained receipts, and health/rollback evidence. The
shared foundation remains privileged, and release concurrency stays serialized until those service
boundaries have been verified.

References: [Shared VPC provisioning](https://cloud.google.com/vpc/docs/provisioning-shared-vpc),
[project provisioning](./provision-workload-foundation.md), and
[architecture](../architecture.md).
