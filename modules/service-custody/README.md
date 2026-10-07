# Service custody

This module gives each registered service and trust zone protected state and receipt folders in
the existing management buckets. It creates no deployment identity, federation provider or runtime.
The protected foundation workflow is the writer; the plan identity receives read-only inspection.

Production selects services with `service_release_zones`. The `private` and `public-api` entries
resolve to their respective shared projects. The platform-only `public` zone cannot enroll backend
services. See the [onboarding runbook](../../docs/runbooks/provision-service-projects.md#shared-project-release-boundaries).

| Coordinate | Contract                                                                                                                        |
| ---------- | ------------------------------------------------------------------------------------------------------------------------------- |
| State      | `workloads/<environment>/<zone>/<project>/<service>/release/` in the management state bucket.                                   |
| Receipts   | The sibling `production/` folder in the management receipt bucket.                                                              |
| Inspection | State-folder read access and exact operation, native-completion and rotation record reads; no receipt writes or bucket listing. |
| Output     | Schema 2 carries service, zone, project and storage coordinates.                                                                |

The dedicated-project compatibility caller uses `zone = null` and preserves its schema-1 storage
paths. Selecting either profile does not copy, adopt or delete existing state or receipts.
Managed folders retain deletion prevention. Their IAM is additive; ancestor grants still apply.
Foundation remains a high-trust administrator, and native release admission retains per-service guards.

No bucket or compute capacity is created here. Stored objects and operations remain usage-priced.
The management bootstrap owns [saved-plan expiration](../../bootstrap/README.md#plan-artifact-expiration).
