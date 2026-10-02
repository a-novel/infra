package workflow_test

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/a-novel/infra/internal/workflow"
)

func TestLegacyMaintenanceRecoveryInputs(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, root, service, key, value string
	}{
		{name: "Success"},
		{name: "WrongRoot", root: "service-foundation"},
		{name: "WrongService", service: "json-keys"},
		{name: "Disabled", key: "LEGACY_DATABASE_RECOVERY_ENABLED"},
		{name: "MaintenanceDisabled", key: "LEGACY_DATABASE_MAINTENANCE_ENABLED"},
		{name: "ReleasesEnabled", key: "PRODUCTION_RELEASES_ENABLED", value: "true"},
		{name: "Unpaused", key: "PRODUCTION_RELEASES_ENABLED"},
		{name: "WrongEvent", key: "GITHUB_EVENT_NAME", value: "push"},
		{name: "WrongRepository", key: "GITHUB_REPOSITORY", value: "other/infra"},
		{name: "WrongBranch", key: "GITHUB_REF", value: "refs/heads/feature"},
		{name: "WrongWorkflow", key: "GITHUB_WORKFLOW_REF", value: "a-novel/infra/.github/workflows/drift.yaml@refs/heads/master"},
		{name: "MissingCommit", key: "GITHUB_SHA"},
		{name: "WrongGeneration", key: "FOUNDATION_GUARD_GENERATION", value: "43"},
		{name: "WrongConfirmation", key: "FOUNDATION_CONFIRM", value: "RECOVER LEGACY 43"},
		{name: "UnexpectedPlan", key: "FOUNDATION_PLAN_ID", value: "123-1"},
		{name: "InvalidConfig", key: "FOUNDATION_CONFIG", value: "invalid"},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			env := map[string]string{
				"FOUNDATION_OPERATION": "recover-legacy", "FOUNDATION_GUARD_GENERATION": "42", "FOUNDATION_CONFIRM": "RECOVER LEGACY 42",
				"LEGACY_DATABASE_RECOVERY_ENABLED": "true", "LEGACY_DATABASE_MAINTENANCE_ENABLED": "true", "PRODUCTION_RELEASES_ENABLED": "false",
				"GITHUB_REPOSITORY": "a-novel/infra", "GITHUB_REF": "refs/heads/master", "GITHUB_SHA": strings.Repeat("a", 40),
				"GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_WORKFLOW_REF": "a-novel/infra/.github/workflows/foundation.yaml@refs/heads/master",
				"FOUNDATION_CONFIG": `{"private":"not-for-logs"}`,
			}
			if testCase.key != "" {
				env[testCase.key] = testCase.value
			}
			root, service := "foundation", "none"
			if testCase.root != "" {
				root = testCase.root
			}
			if testCase.service != "" {
				service = testCase.service
			}
			file := filepath.Join(t.TempDir(), "inputs.json")
			var output bytes.Buffer
			code := workflow.FoundationInputs([]string{"prepare", root, service, file}, func(key string) string { return env[key] }, &output, &output)
			require.NotContains(t, output.String(), "not-for-logs")
			if testCase.name == "Success" {
				require.Zero(t, code, output.String())
				data, err := os.ReadFile(file)
				require.NoError(t, err)
				require.Equal(t, env["FOUNDATION_CONFIG"], string(data))
			} else {
				require.NotZero(t, code)
				require.NoFileExists(t, file)
			}
		})
	}
}
