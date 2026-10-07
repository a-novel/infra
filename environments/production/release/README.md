# Shared application operations

This production root owns the hourly JSON Keys rotation schedule and five invocation tags.
Application services and jobs belong to the [service release roots](../../service-release/).
Database backups belong to the [foundation](../foundation/) and its native pgBackRest workers.

## State and authority

The protected `production-release` workflow plans and applies this root at the existing `release/`
backend prefix. Resource addresses stay stable: the three `application` job tags, the `json_keys`
internal API tag, the `json_keys_smoke` job tag, and `json_keys_rotation[0]`.

The rotation scheduler invokes only `agora-json-keys-rotatekeys`, hourly at minute 10 UTC, with the
foundation-owned scheduler identity and no execution overrides. The root preserves an operator's
temporary pause; release and maintenance operations own its coordinated pause/resume lifecycle.

Invocation classes remain `release` for migration/smoke jobs, `scheduled` for rotation, and
`internal` for JSON Keys gRPC. The foundation owns the tag values and conditional invocation IAM.

## Inputs and outputs

Inputs are the private workload project ID, region, foundation scheduler identity and the three
permanent invocation tag values. Outputs identify only the root and region. No secret payload,
database image, application release or recovery-point configuration belongs in this root.

## Operations

Use the retained production operations workflow's explicit `plan` and `apply` actions. Inspect the
exact private saved plan before applying. Deletions require the normal trusted assessment and
maintainer-approved deletion gate; a successful plan never authorizes a different apply.

Validate locally with `./ops/check-root.sh release`. The mock plans protect existing resource
addresses, invocation classes, rotation target and scheduler identity.
