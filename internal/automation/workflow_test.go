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

func TestRolloutObservationWorkflow(t *testing.T) {
	t.Parallel()
	data, err := os.ReadFile("../../.github/workflows/drift.yaml")
	require.NoError(t, err)
	var document struct {
		Permissions, Concurrency object
		Jobs                     map[string]workflowJob
	}
	require.NoError(t, yaml.Unmarshal(data, &document))
	job := document.Jobs["observe-rollout"]
	require.Len(t, job.Steps, 5)
	var steps []string
	for _, item := range job.Steps {
		uses, _, _ := strings.Cut(item.Uses, "@")
		steps = append(steps, uses)
		require.Empty(t, item.If, "observation steps cannot skip scope checks or swallow failure")
	}
	for _, testCase := range []struct {
		name       string
		want, have any
	}{
		{"DefaultPermissions", object{}, document.Permissions},
		{"ReaderConcurrency", object{"group": "${{ inputs.operation == 'observe-rollout' && 'rollout-observation' || 'production-infrastructure' }}", "cancel-in-progress": false}, document.Concurrency},
		{"DispatchBoundary", "github.ref == 'refs/heads/master' && github.event_name == 'workflow_dispatch' && inputs.operation == 'observe-rollout'", job.If},
		{"JobPermissions", map[string]string{"contents": "read", "id-token": "write"}, job.Permissions},
		{"JobDeadline", 20, job.Timeout},
		{"StepOrder", []string{"actions/checkout", "$/.github/actions/setup-infra", "", "google-github-actions/auth", "$/.github/actions/observe-rollout"}, steps},
		{"CleanCheckout", object{"persist-credentials": false}, job.Steps[0].With},
		{"ScopeInputs", object{
			"SERVICE_ROLLOUT_OBSERVATION_ENABLED": "${{ vars.SERVICE_ROLLOUT_OBSERVATION_ENABLED }}",
			"GCP_JSON_KEYS_ROLLOUT_PARENT":        "${{ vars.GCP_JSON_KEYS_ROLLOUT_PARENT }}",
			"SELECTED_SERVICE":                    "${{ inputs.service }}", "RELEASE_ID": "${{ inputs.release_id }}", "ROLLOUT_ID": "${{ inputs.rollout_id }}",
		}, job.Steps[2].Env},
		{"ScopeCommand", "set -euo pipefail\ninfra observation-inputs \"${SELECTED_SERVICE}\" \"${RELEASE_ID}\" \"${ROLLOUT_ID}\" >>\"${GITHUB_OUTPUT}\"\n", job.Steps[2].Run},
		{"ReadOnlyIdentity", object{
			"workload_identity_provider": "${{ vars.GCP_PLAN_WORKLOAD_IDENTITY_PROVIDER }}",
			"service_account":            "${{ vars.GCP_PLAN_SERVICE_ACCOUNT }}",
			"create_credentials_file":    true, "export_environment_variables": true,
		}, job.Steps[3].With},
		{"ObserverHandoff", object{"rollout": "${{ steps.scope.outputs.rollout }}", "timeout": "10m"}, job.Steps[4].With},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			require.Equal(t, testCase.want, testCase.have)
		})
	}
	for _, name := range []string{"inspect", "health", "assess-resource-deletion"} {
		require.Contains(t, document.Jobs[name].If, "inputs.operation ==")
		require.NotContains(t, document.Jobs[name].If, "observe-rollout")
	}
	var raw map[string]any
	require.NoError(t, yaml.Unmarshal(data, &raw))
	encoded, err := json.Marshal(raw["jobs"].(map[string]any)["observe-rollout"])
	require.NoError(t, err)
	require.NotRegexp(t, `continue-on-error|always\(\)|secrets\.|gcloud|opentofu|submit-release|submit-rollout`, string(encoded))
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
