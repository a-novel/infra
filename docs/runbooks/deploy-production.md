# Deploy and roll back production

Routine API deployments use [Release APIs with OpenTofu](./submit-release.md). Follow that procedure
for image publication, private migrations, candidate health checks, reviewed traffic promotion and
interrupted operations. The protected foundation workflow owns the service/zone release roots.
Merging an image-manifest update does not deploy it automatically.

## Operator context

Use clean, current `master` and the registered service/zone configuration. Keep plans, input
documents and completion receipts private. The [operator command reference](../../ops/README.md)
covers credentials and workflow inspection; database maintenance remains a separate operation.

## 4. Store the protected non-payload release configuration

Routine inputs live in `SERVICE_JOB_BOOTSTRAPS_JSON` in the protected `production-foundation`
environment. Each service/zone entry is an ordinary
[service-release tfvars object](../../environments/service-release/README.md).
Select immutable images and enabled numeric secret-version references; never include payloads.
Review configuration changes as a candidate before promotion.

The retained root still uses its last converged inputs for backup resources and historical
recovery. Do not replace those inputs with native API configuration or replay an old whole-release
receipt to change API traffic.

## 7. Verify deployment and rotation

Require a successful exact apply, the intended revision at 100% traffic, healthy dependencies and
its private completion record. Authentication runs in public-api; JSON Keys gRPC and migrations run
in private. After JSON Keys promotion succeeds, verify that its existing hourly rotation schedule
is enabled. Retain working backups and check their restore evidence separately.

Application health checks must pass their dependency contract, not merely return HTTP 200.
Use [SMTP delivery validation](./configure-hosted-smtp.md#5-validate-without-exposing-the-credential)
for the external email path. Keep private diagnostics out of public workflow logs.

## Rollback and data recovery

A failed candidate leaves the preceding serving revision unchanged. A failure after promotion
requires inspection: the new revision may already receive traffic. Review schema compatibility,
then plan the selected service's native traffic change; do not replay the retired imperative
rollback command or rerun a migration to recover a lost response.

Traffic rollback does not reverse migrations or repair rows. For damaged data, use
[PostgreSQL recovery](./backup-and-restore-postgresql.md) or
[disaster recovery](./disaster-recovery.md). Historical receipts and their recovery readers remain
available for those procedures.
