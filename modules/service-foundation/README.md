# Service application prerequisites

This module owns durable application prerequisites inside one production service project: its
runtime identity, secret-container grants, regional image repositories and operations email channel.
It supports the reviewed JSON Keys and Authentication contracts. A new service needs an explicit
runtime-secret contract before using this module.

**Code only:** no production root calls this module. It creates no API, database, job, schedule,
secret payload or release. Existing workloads and their ownership remain unchanged.

## Ownership and authority

The protected service foundation owns these resources. The shared
[workload-project module](../workload-project) owns the project, APIs, Google agents, release identity
and storage namespaces. The [rollout module](../cloud-run-rollout) owns the API deployment workers,
probe and Cloud Deploy configuration. Routine service release must not apply either foundation.

| Principal                     | Resource access declared here                                             |
| ----------------------------- | ------------------------------------------------------------------------- |
| `agora-<service>` application | Secret Accessor on that service's two management-project runtime secrets. |
| Project-local `infra-release` | Artifact Registry Writer on `agora-production` only.                      |
| Management `infra-recovery`   | Artifact Registry Reader on both service repositories.                    |

Authentication receives its PostgreSQL and SMTP credentials; JSON Keys receives its PostgreSQL
credential and master key. Neither application receives backup credentials, the initializer password,
peer secrets, image publication rights, project roles or an impersonation grant. Secret IAM applies
to the container; release configuration separately selects verified enabled numeric versions.
OpenTofu never reads their payloads. Inherited IAM can broaden these grants and requires live inspection.

`agora-production` holds the complete service image family. `agora-tooling` holds the pinned verifier.
Both use immutable tags and prevent deletion. No cleanup policy expires images: retained receipts and
Cloud Deploy releases may still reference them. The service release account cannot publish verifier
code. Its separately approved promoter and provenance check remain activation prerequisites; this
module grants no verifier writer. Cloud Run's same-project service agent pulls containers, while the
rollout module grants its custom workers exact repository reads. The application identity needs none.

## Composition

A future protected foundation caller supplies the existing service-project output and orders this
module after its API and identity setup:

```hcl
module "application" {
  source = "../../../modules/service-foundation"

  project_id             = module.project.project_id
  service                = "json-keys"
  management_project_id  = var.management_project_id
  region                 = var.region
  operations_alert_email = var.operations_alert_email

  depends_on = [module.project]
}
```

Publish the versioned `runtime` output without granting readers access to foundation state. Its
`service_account` and `notification_channels` feed the rollout inputs of those names
(`runtime_service_account` for the account); its repository URLs identify promotion destinations.
The output waits for runtime-secret and application-publisher grants. The caller must separately order
Cloud Deploy after Shared VPC attachment and host-owned subnet/firewall grants.
The inactive [service-jobs module](../service-jobs) consumes the same `runtime` contract for
migrations and, for JSON Keys, rotation. The separate [job-access module](../service-job-access)
grants routine release authority on those exact jobs after protected bootstrap creates them.
Its IAM stays foundation-owned; API rollout workers receive no application-job rights.

The executor needs repository and notification-channel administration in the service project;
`workload-project` grants those to the existing protected foundation account. Service-account
administration is already present. The executor also needs secret-IAM maintenance permission on
the selected management-project containers. The rollout module has additional execution/attachment
prerequisites of its own.

Before activation, publish and verify the reviewed verifier digest in `agora-tooling`, inspect
effective IAM (including denied peer/initializer/tooling-write access), and test notification delivery.
Channel creation does not prove email receipt. Database/job resources, trusted release parameters,
same-service serialization, success receipts and the one-writer handoff are still separate work.

The foundation root's native mocked tests cover both secret contracts, repository custody, outputs,
and rejected boundaries. They make no cloud calls and are not evidence of live permissions or health.
References: [repository IAM](https://docs.cloud.google.com/artifact-registry/docs/access-control),
[immutable tags and deletion protection](https://github.com/hashicorp/terraform-provider-google/blob/v8.2.0/website/docs/r/artifact_registry_repository.html.markdown),
[secret IAM](https://docs.cloud.google.com/secret-manager/docs/access-control).
