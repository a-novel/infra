# Project shell

The protected foundation owns this module. It provisions a Google Cloud project,
its APIs and service agents, bounded log retention, and foundation/assessment IAM.
Labels describe the caller's ownership boundary; a service label is optional.
Release identities, federation, state folders, workloads and Shared VPC attachment
belong to callers.

The current caller is the [workload-project compatibility module](../workload-project).
Its declarative moves preserve existing resource identities while separating project
ownership from service release authority. That caller still requires distinct projects
per service. Shared trust-zone placement needs workload-scoped IAM, guards and storage
coordinates before activation.

Project deletion protection, default-account deprivileging and existing maintenance
permissions are retained. Foundation remains a high-trust administrator with project
IAM and Compute instance administration. This module does not make shared workloads
mutually isolated by itself.

The foundation's mocked tests cover both direct project-shell use and compatibility
outputs. Live provisioning requires a separately reviewed saved plan. Review owned
obsolete projects and billing capacity before creating any new projects; public-admin
and staging remain deferred.
