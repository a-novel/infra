// Package preflight checks release prerequisites through the existing registry
// and cloud CLIs. It reads image evidence and secret metadata, never payloads,
// and grants no authority to deploy or execute jobs.
package preflight
