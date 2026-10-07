package tests_test

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
	"go.yaml.in/yaml/v3"
)

func TestReleasePermissions(t *testing.T) {
	t.Parallel()
	release := loadWorkflow(t, "workflows/release.yaml")
	job := release.Jobs["release-permissions"]
	for _, testCase := range []struct{ name, expected, actual string }{
		{"Manual", "github.event_name == 'workflow_dispatch'", job.If},
		{"Master", "github.ref == 'refs/heads/master'", job.If},
		{"Action", "inputs.action == 'check-release-permissions'", job.If},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			require.Contains(t, testCase.actual, testCase.expected)
		})
	}
	require.Equal(t, "${{ matrix.environment }}", job.Environment)
	require.Equal(t, map[string]string{"contents": "read", "id-token": "write"}, job.Permissions)
	require.NotContains(t, job.If, "ENABLED")
	require.Nil(t, job.Needs)
	require.Len(t, job.Steps, 4)
	require.Equal(t, false, job.Steps[0].With["persist-credentials"])
	require.Equal(t, "$/.github/actions/setup-infra", job.Steps[1].Uses)
	require.Equal(t, "google-github-actions/auth@v3.0.0", job.Steps[2].Uses)
	require.Equal(t, "${{ matrix.account }}", job.Steps[2].With["service_account"])
	require.Equal(t, "projects/232403541574/locations/global/workloadIdentityPools/github-actions/providers/${{ matrix.provider }}", job.Steps[2].With["workload_identity_provider"])
	require.Contains(t, job.Steps[3].Run, "infra custody permissions check")
	require.Contains(t, job.Steps[3].Run, "a-novel-management-prod-232403541574-tofu-state")
	for _, step := range job.Steps {
		for _, value := range step.Env {
			require.NotContains(t, value, "secrets.")
		}
		require.NotContains(t, step.Run, "${{")
		require.NotContains(t, step.Run, "infra service-release")
		require.NotContains(t, step.Run, "tofu ")
	}
	var raw struct {
		Jobs map[string]struct {
			Timeout  int `yaml:"timeout-minutes"`
			Strategy struct {
				FailFast bool `yaml:"fail-fast"`
				Matrix   struct{ Include []map[string]string }
			}
		}
	}
	require.NoError(t, yaml.Unmarshal([]byte(read(t, "../.github/workflows/release.yaml")), &raw))
	selected := raw.Jobs["release-permissions"]
	require.Equal(t, 15, selected.Timeout)
	require.False(t, selected.Strategy.FailFast)
	entries := selected.Strategy.Matrix.Include
	require.Len(t, entries, 2)
	for index, testCase := range []struct{ service, zone, project, account, provider string }{
		{"json-keys", "private", "a-novel-production-prod", "infra-json-keys-private", "r-fa8fb0969708fa1eae6efbaa7182"},
		{"authentication", "public-api", "a-novel-public-api-prod", "infra-authentication-api", "r-c4ce9a8eb5aa6471505b4ef23ae7"},
	} {
		t.Run(testCase.service, func(t *testing.T) {
			t.Parallel()
			entry := entries[index]
			require.Equal(t, map[string]string{
				"environment": "production-" + testCase.service + "-" + testCase.zone + "-release",
				"account":     testCase.account + "@" + testCase.project + ".iam.gserviceaccount.com",
				"provider":    testCase.provider,
				"scope":       strings.Join([]string{"workloads/production", testCase.zone, testCase.project, testCase.service}, "/"),
				"peer":        entries[1-index]["scope"],
			}, entry)
		})
	}
}
