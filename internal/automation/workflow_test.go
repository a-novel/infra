package automation_test

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
	"go.yaml.in/yaml/v3"
)

type step struct {
	Name, Uses, Run, If string
	With, Env           object
}

type workflowJob struct {
	If, Name, Environment string
	Permissions           map[string]string
	Timeout               int `yaml:"timeout-minutes"`
	Needs                 any
	Steps                 []step
	Concurrency           object
}

func TestReadOnlyWorkflows(t *testing.T) {
	t.Parallel()
	data, err := os.ReadFile("../../.github/workflows/drift.yaml")
	require.NoError(t, err)
	var document struct {
		Permissions, Concurrency object
		Jobs                     map[string]workflowJob
	}
	require.NoError(t, yaml.Unmarshal(data, &document))
	require.Empty(t, document.Permissions)
	require.Equal(t, object{
		"group":              "${{ inputs.operation == 'inspect-operation' && 'operation-inspection' || inputs.operation == 'observe-rollout' && 'rollout-observation' || 'production-infrastructure' }}",
		"cancel-in-progress": false,
	}, document.Concurrency)
	var raw map[string]any
	require.NoError(t, yaml.Unmarshal(data, &raw))
	for _, testCase := range []struct {
		name, environment, reader, scopeCommand, readerCommand string
		timeout                                                int
		scopeEnv, readerEnv, readerWith                        object
	}{
		{
			name: "observe-rollout", timeout: 20, reader: "$/.github/actions/observe-rollout",
			scopeCommand: "set -euo pipefail\ninfra observation-inputs observe-rollout \"${SELECTED_SERVICE}\" \"${RELEASE_ID}\" \"${ROLLOUT_ID}\" >>\"${GITHUB_OUTPUT}\"\n",
			scopeEnv: object{
				"SERVICE_ROLLOUT_OBSERVATION_ENABLED": "${{ vars.SERVICE_ROLLOUT_OBSERVATION_ENABLED }}",
				"GCP_JSON_KEYS_ROLLOUT_PARENT":        "${{ vars.GCP_JSON_KEYS_ROLLOUT_PARENT }}",
				"SELECTED_SERVICE":                    "${{ inputs.service }}", "RELEASE_ID": "${{ inputs.release_id }}", "ROLLOUT_ID": "${{ inputs.rollout_id }}",
			},
			readerWith: object{"rollout": "${{ steps.scope.outputs.rollout }}", "timeout": "10m"},
		},
		{
			name: "inspect-operation", timeout: 10, environment: "production-foundation",
			scopeCommand: "set -euo pipefail\nargs=(inspect-operation \"${SELECTED_SERVICE}\")\n" +
				"if [[ -n \"${GUARD_GENERATION}\" ]]; then args+=(\"${GUARD_GENERATION}\"); fi\ninfra observation-inputs \"${args[@]}\" >>\"${GITHUB_OUTPUT}\"\n",
			readerCommand: "set -euo pipefail\nargs=(operation inspect \"${STATE_BUCKET}\" \"${SELECTED_PROJECT}\")\n" +
				"if [[ -n \"${GUARD_GENERATION}\" ]]; then args+=(\"${GUARD_GENERATION}\"); fi\ninfra custody \"${args[@]}\" | tee \"${GITHUB_STEP_SUMMARY}\"\n",
			scopeEnv: object{
				"FOUNDATION_CONFIG": "${{ secrets.FOUNDATION_TFVARS_JSON }}", "MANAGEMENT_PROJECT_ID": "${{ vars.GCP_MANAGEMENT_PROJECT_ID }}",
				"STATE_BUCKET": "${{ vars.GCP_STATE_BUCKET }}", "SELECTED_SERVICE": "${{ inputs.service }}", "GUARD_GENERATION": "${{ inputs.guard_generation }}",
			},
			readerEnv: object{
				"FOUNDATION_CONFIG": "${{ secrets.FOUNDATION_TFVARS_JSON }}", "MANAGEMENT_PROJECT_ID": "${{ vars.GCP_MANAGEMENT_PROJECT_ID }}",
				"STATE_BUCKET": "${{ vars.GCP_STATE_BUCKET }}", "SELECTED_PROJECT": "${{ steps.scope.outputs.project }}", "GUARD_GENERATION": "${{ inputs.guard_generation }}",
			},
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			job := document.Jobs[testCase.name]
			require.Len(t, job.Steps, 5)
			var steps []string
			for _, item := range job.Steps {
				uses, _, _ := strings.Cut(item.Uses, "@")
				steps = append(steps, uses)
				require.Empty(t, item.If, "readers cannot skip authorization or swallow failure")
			}
			for _, contract := range []struct {
				name       string
				want, have any
			}{
				{"DispatchBoundary", "github.ref == 'refs/heads/master' && github.event_name == 'workflow_dispatch' && inputs.operation == '" + testCase.name + "'", job.If},
				{"Environment", testCase.environment, job.Environment},
				{"Permissions", map[string]string{"contents": "read", "id-token": "write"}, job.Permissions},
				{"Deadline", testCase.timeout, job.Timeout},
				{"StepOrder", []string{"actions/checkout", "$/.github/actions/setup-infra", "", "google-github-actions/auth", testCase.reader}, steps},
				{"CleanCheckout", object{"persist-credentials": false}, job.Steps[0].With},
				{"ScopeInputs", testCase.scopeEnv, job.Steps[2].Env},
				{"ScopeCommand", testCase.scopeCommand, job.Steps[2].Run},
				{"ReadOnlyIdentity", object{
					"workload_identity_provider": "${{ vars.GCP_PLAN_WORKLOAD_IDENTITY_PROVIDER }}", "service_account": "${{ vars.GCP_PLAN_SERVICE_ACCOUNT }}",
					"create_credentials_file": true, "export_environment_variables": true,
				}, job.Steps[3].With},
				{"ReaderInputs", testCase.readerEnv, job.Steps[4].Env},
				{"ReaderCommand", testCase.readerCommand, job.Steps[4].Run},
				{"ReaderHandoff", testCase.readerWith, job.Steps[4].With},
			} {
				t.Run(contract.name, func(t *testing.T) { require.Equal(t, contract.want, contract.have) })
			}
			encoded, err := json.Marshal(raw["jobs"].(map[string]any)[testCase.name])
			require.NoError(t, err)
			require.NotRegexp(t, `continue-on-error|always\(\)|gcloud|opentofu|submit-release|submit-rollout`, string(encoded))
			if testCase.name == "observe-rollout" {
				require.NotContains(t, string(encoded), "secrets.")
			}
		})
	}
	for _, name := range []string{"inspect", "health", "assess-resource-deletion"} {
		require.Contains(t, document.Jobs[name].If, "inputs.operation ==")
		require.NotContains(t, document.Jobs[name].If, "observe-rollout")
		require.NotContains(t, document.Jobs[name].If, "inspect-operation")
	}
}

func TestWorkflowBoundaries(t *testing.T) {
	t.Parallel()
	load := func(path string, value any) string {
		t.Helper()
		data, err := os.ReadFile(filepath.Join("../..", path))
		require.NoError(t, err)
		require.NoError(t, yaml.Unmarshal(data, value))
		return string(data)
	}
	var refresh struct {
		On          object
		Permissions object
		Jobs        map[string]workflowJob
	}
	source := load(".github/workflows/refresh-deletion-gates.yaml", &refresh)
	require.Equal(t, []string{"# zizmor: ignore[dangerous-triggers]"}, regexp.MustCompile(`#\s*zizmor:\s*ignore\[[^\]]+\]`).FindAllString(source, -1))
	require.Equal(t, object{
		"pull_request_target": object{"branches": []any{"master"}, "types": []any{"labeled", "unlabeled"}},
		"workflow_run":        object{"workflows": []any{"main", "production drift"}, "types": []any{"completed"}},
	}, refresh.On)
	require.Empty(t, refresh.Permissions)
	require.Contains(t, refresh.Jobs["refresh"].If, "allow-resource-deletion")
	require.Equal(t, object{"group": "image-assessment-request", "cancel-in-progress": false}, refresh.Jobs["assess-images"].Concurrency)
	for name, command := range map[string]string{"refresh": "infra refresh-deletion-gates", "assess-images": "infra assess-images dispatch"} {
		job := refresh.Jobs[name]
		require.Equal(t, map[string]string{"actions": "write", "contents": "read", "pull-requests": "read"}, job.Permissions)
		require.Empty(t, job.Environment)
		require.Equal(t, 5, job.Timeout)
		require.Len(t, job.Steps, 3)
		require.Contains(t, job.Steps[0].Uses, "actions/checkout@")
		require.Equal(t, object{"ref": "master", "persist-credentials": false}, job.Steps[0].With)
		require.Equal(t, "$/.github/actions/setup-infra", job.Steps[1].Uses)
		require.Contains(t, job.Steps[2].Run, command)
		require.Equal(t, "${{ github.token }}", job.Steps[2].Env["GH_TOKEN"])
		data, err := json.Marshal(job)
		require.NoError(t, err)
		require.NotRegexp(t, `secrets\.|id-token|google-github-actions|artifact|cache|pnpm|setup-node`, string(data))
		require.NotContains(t, job.Steps[2].Run, "${{")
	}
	var main, drift struct{ Jobs map[string]workflowJob }
	load(mainPath, &main)
	for name, job := range main.Jobs {
		require.NotEqual(t, "resource-deletion-gate", job.Name, name)
		needs, err := json.Marshal(job.Needs)
		require.NoError(t, err)
		require.NotContains(t, string(needs), "resource-deletion-gate", name)
		require.NotContains(t, string(needs), "${{", name)
	}
	load(".github/workflows/drift.yaml", &drift)
	steps := drift.Jobs["assess-resource-deletion"].Steps
	build, verify, auth := -1, -1, -1
	for i, s := range steps {
		if s.Uses == "$/.github/actions/setup-infra" {
			build = i
			require.Empty(t, s.If)
			require.Equal(t, "trusted", s.With["working_directory"])
		}
		if strings.Contains(s.Run, "infra assess-images verify") {
			verify = i
			require.Equal(t, "inputs.operation == 'assess-image-update'", s.If)
			require.Equal(t, "${{ github.token }}", s.Env["GH_TOKEN"])
		}
		if strings.HasPrefix(s.Uses, "google-github-actions/auth@") {
			auth = i
		}
		if s.With["path"] == "candidate" || strings.HasPrefix(s.Uses, "opentofu/") || strings.Contains(s.Run, "resolve-resource-deletion-assessment.sh") {
			require.Equal(t, "inputs.operation == 'assess-pull-request'", s.If)
		}
		if strings.Contains(s.Run, "infra inspect assess") {
			require.Contains(t, s.Run, "candidate=--image-only")
			require.NotContains(t, s.Run, "${{")
		}
	}
	require.GreaterOrEqual(t, build, 0)
	require.Greater(t, verify, build)
	require.Greater(t, auth, verify)
	var action struct {
		Inputs object
		Runs   struct{ Steps []step }
	}
	load(".github/actions/setup-infra/action.yaml", &action)
	require.Equal(t, ".", action.Inputs["working_directory"].(object)["default"])
	require.Equal(t, false, action.Runs.Steps[0].With["cache"])
	require.Equal(t, "${{ inputs.working_directory }}/go.mod", action.Runs.Steps[0].With["go-version-file"])
	require.Contains(t, action.Runs.Steps[1].Run, "go build -mod=readonly")
}
