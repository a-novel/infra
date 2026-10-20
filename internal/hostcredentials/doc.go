// Package hostcredentials loads a host's pinned pgBackRest TLS files from Secret Manager, checks
// them, and publishes them before PostgreSQL or the pgBackRest server starts on the host.
//
// The caller owns the private parent directory, and starts the consumer only once Deliver
// succeeds. Certificates are issued offline, and the host's systemd unit runs the loader in a
// read-only container without capabilities.
package hostcredentials
