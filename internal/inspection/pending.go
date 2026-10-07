package inspection

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/a-novel/infra/internal/workflow"
)

// Pending inputs are available only through the environment-approved assessment
// job. Bootstrap and foundation may have partially applied intent; service inputs
// still come from their completed operations.
func (i *inspector) selectPendingFoundation(head, base, candidate string) error {
	if i.getenv("GITHUB_EVENT_NAME") != "workflow_dispatch" ||
		i.getenv("GITHUB_WORKFLOW_REF") != "a-novel/infra/.github/workflows/drift.yaml@refs/heads/master" ||
		i.getenv("GITHUB_SHA") != base || i.getenv("ASSESSMENT_OPERATION") != "assess-pending-foundation" ||
		!regexp.MustCompile(`^[a-f0-9]{40}$`).MatchString(head) || !filepath.IsAbs(candidate) {
		return failure{77, "Pending foundation inputs require the protected assessment workflow and exact candidate."}
	}
	i.pending = make(map[string]string, 2)
	for _, root := range []string{"foundation", "bootstrap"} {
		data := []byte(i.getenv("PENDING_" + strings.ToUpper(root) + "_CONFIG"))
		if root == "bootstrap" && len(data) == 0 {
			continue
		}
		var config map[string]json.RawMessage
		var management string
		if json.Unmarshal(data, &config) != nil || config == nil ||
			json.Unmarshal(config["management_project_id"], &management) != nil ||
			management != i.getenv("MANAGEMENT_PROJECT_ID") ||
			!regexp.MustCompile(`^[a-z][a-z0-9-]{4,28}[a-z0-9]$`).MatchString(management) ||
			!regexp.MustCompile(`^`+regexp.QuoteMeta(management)+`-[1-9][0-9]*-tofu-state$`).MatchString(i.bucket) {
			return failure{65, "Pending infrastructure inputs do not match the protected management coordinates."}
		}
		if root == "foundation" {
			getenv := func(key string) string {
				if key == "FOUNDATION_CONFIG" {
					return string(data)
				}
				return i.getenv(key)
			}
			if _, err := workflow.ServiceScopes(getenv, i.bucket); err != nil {
				return failure{65, "Pending foundation service registration is invalid."}
			}
		}
		i.pending[root] = filepath.Join(i.scratch, "pending-"+root+".json")
		if err := os.WriteFile(i.pending[root], data, 0o600); err != nil {
			return err
		}
	}
	return nil
}
