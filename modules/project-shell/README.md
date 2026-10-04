# Project shell

The protected foundation owns this module. It provisions a Google Cloud project,
its APIs and service agents, bounded log retention, and foundation/assessment IAM.
Labels describe the caller's ownership boundary; a service label is optional.
Release identities, federation, state folders, workloads and Shared VPC attachment
belong to callers.

The [production foundation](../../environments/production/foundation) uses this module for
shared trust zones. The [workload-project compatibility module](../workload-project) retains
dedicated-project addresses through declarative moves.

Project deletion protection, default-account deprivileging and existing maintenance
permissions are retained. Foundation remains a high-trust administrator with project
IAM and Compute instance administration. This module does not make shared workloads
mutually isolated by itself.

Protected foundation maintains Cloud Run job specifications and service IAM. The plan identity
receives matching policy reads. Production foundation separately grants service creation/update
in the enrolled public-api project and enables its telemetry APIs. Private internal-service IAM
uses its own tag-restricted grant. The platform shell receives neither grant.

The foundation's mocked tests cover both direct project-shell use and compatibility
outputs. Live provisioning requires a separately reviewed saved plan. Review owned
obsolete projects and billing capacity before creating any new projects; public-admin
and staging remain deferred.
