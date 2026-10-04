// Package rollout verifies service-scoped Cloud Deploy revisions through an isolated
// Cloud Run job. Cloud Deploy owns traffic; verification only inspects and probes.
package rollout
