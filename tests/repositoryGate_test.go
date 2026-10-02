package tests_test

import (
	_ "embed"
	"os/exec"
	"testing"

	"github.com/stretchr/testify/require"
)

//go:embed testdata/repositoryGate.yaml
var repositoryGate []byte

// TestRepositoryGate exercises the operator preflight without GitHub credentials or mutations.
func TestRepositoryGate(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, filter string
		code         int
	}{
		{"Success", ".", 0},
		{"Success/Reordered", ".rules[0].parameters.required_status_checks |= reverse | .bypass_actors |= reverse", 0},
		{"Error/MissingTooling", `del(.rules[0].parameters.required_status_checks[] | select(.context == "lint-tooling"))`, 77},
		{"Error/MissingBackup", `del(.rules[0].parameters.required_status_checks[] | select(.context == "test-backup"))`, 77},
		{"Error/MissingGo", `del(.rules[0].parameters.required_status_checks[] | select(.context == "test-go"))`, 77},
		{"Error/MissingRelease", `del(.rules[0].parameters.required_status_checks[] | select(.context == "validate-release"))`, 77},
		{"Error/MissingDeletionGate", `del(.rules[0].parameters.required_status_checks[] | select(.context == "resource-deletion-gate"))`, 77},
		{"Error/UnexpectedCheck", `.rules[0].parameters.required_status_checks += [{context: "unexpected", integration_id: 15368}]`, 77},
		{"Error/WrongSource", `(.rules[0].parameters.required_status_checks[] | select(.context == "resource-deletion-gate").integration_id) = 999`, 77},
		{"Error/Disabled", `.enforcement = "disabled"`, 77},
		{"Error/DependencyBypass", `.bypass_actors += [{actor_id: 101, actor_type: "Integration", bypass_mode: "always"}]`, 77},
		{"Error/MissingBypass", `del(.bypass_actors[0])`, 77},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			f := setup(t)
			awk, err := exec.LookPath("awk")
			require.NoError(t, err)
			f.link(t, "awk", awk)
			f.command(t, "gh")
			fixture := fixtureYAML[object](t, repositoryGate)
			code, ruleset := f.run(t, "jq", "-cn", "--argjson", "ruleset", jsonText(t, fixture), "$ruleset | "+testCase.filter)
			expectCode(t, 0, code, ruleset)
			calls := []invocation{
				{Name: "gh", Args: []string{"auth", "status"}},
				{Name: "gh", Args: []string{"api", "repos/a-novel/infra/rulesets", "--jq", `.[] | select(.name == "master") | .id`}, Output: "42"},
				{Name: "gh", Args: []string{"api", "repos/a-novel/infra/rulesets/42"}, Output: ruleset},
				{Name: "gh", Args: []string{"api", "--paginate", "orgs/a-novel/installations?per_page=100", "--jq", `.installations[] | [.app_slug, .app_id] | @tsv`}, Output: "anovelbot-dependencies\t101\nanovelbot-publish\t102\nanovelbot-agent\t103\n"},
			}
			if testCase.code == 0 {
				calls = append(calls, invocation{Name: "gh", Args: []string{"variable", "list", "--repo", "a-novel/infra", "--json", "name,value", "--jq", `[.[] | select(.name == "PRODUCTION_RELEASES_ENABLED")]`}, Output: `[{"name":"PRODUCTION_RELEASES_ENABLED","value":"false"}]`})
			}
			f.expect(t, calls)
			code, output := f.script(t, "verify-repository-gate")
			expectCode(t, testCase.code, code, output)
			require.JSONEq(t, "[]", read(t, f.env["INFRA_TEST_SEQUENCE"]))
			if testCase.code == 0 {
				require.Contains(t, output, `"dependency_bot_bypassed": false`)
			} else {
				require.Contains(t, output, "The master required checks, Actions source, or bypass policy is not reconciled.")
			}
		})
	}
}
