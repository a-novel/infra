// Package artifact verifies release prerequisites and promotes exact image
// families. The compiler owns inventory policy; Google's registry client owns
// OCI transfers. Preflight is read-only, and promotion never deploys a workload.
package artifact
