// Package diagnostics limits public OpenTofu failures to a fixed vocabulary.
package diagnostics

import (
	"regexp"
	"slices"
	"strings"
)

// The runner's diagnostic rows may carry private source metadata. Only the fixed
// reason vocabulary from ops/tofu-gate.sh may cross this boundary.
var failureRow = regexp.MustCompile(`(?m)^(ZONE_RESOURCE_POOL_EXHAUSTED|RESOURCE_EXHAUSTED|PERMISSION_DENIED|UNAUTHENTICATED|NOT_FOUND|INVALID_ARGUMENT|FAILED_PRECONDITION|ALREADY_EXISTS|ABORTED|DEADLINE_EXCEEDED|UNAVAILABLE|INTERNAL|CONFIGURATION|UNKNOWN)\t(google_[a-z0-9_]+|-)\t([A-Za-z0-9][A-Za-z0-9._-]*:[1-9][0-9]*|-)\t[1-9][0-9]*$`)

// Categories returns only fixed failure reasons from the gate's private TSV rows.
func Categories(data []byte) string {
	categories := []string{}
	for _, row := range failureRow.FindAllSubmatch(data, -1) {
		categories = append(categories, string(row[1]))
	}
	slices.Sort(categories)
	return strings.Join(slices.Compact(categories), ", ")
}
