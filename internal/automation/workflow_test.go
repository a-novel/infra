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
			require.Equal(t, "inputs.operation == 'assess-image-update'", s.If)
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
		if strings.Contains(s.Run, "prepare-resource-deletion-assessment.sh") {
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
