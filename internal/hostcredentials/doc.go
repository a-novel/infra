// Package hostcredentials prepares pinned pgBackRest TLS files for a stopped host runtime.
// The caller owns the private ephemeral parent directory and starts the consumer only after success.
// Certificate issuance, rotation and runtime confinement belong to the host's protected owner.
package hostcredentials
