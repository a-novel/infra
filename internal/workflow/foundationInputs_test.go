package workflow_test

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/a-novel/infra/internal/workflow"
)

func TestFoundationInputs(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, root, service, field, value, variable string
		valid                                       bool
	}{
		{name: "Bootstrap", root: "bootstrap", service: "none", valid: true},
		{name: "Shared", root: "foundation", service: "none", valid: true},
		{name: "JSONKeys", valid: true},
		{name: "Authentication", service: "authentication", valid: true},
		{name: "PeerProject", field: "project_id", value: "agora-peer-test"},
		{name: "PeerBucket", field: "state_bucket", value: "agora-peer-test-123-tofu-state"},
		{name: "Management", field: "management_project_id", value: "agora-peer-test"},
		{name: "Region", field: "region", value: "us-central1"},
		{name: "CaseSensitiveProject", field: "project_id", value: ""},
		{name: "ExtraUppercaseService", field: "SERVICE", value: "authentication", valid: true},
		{name: "CaseSensitiveRegistration", variable: "FOUNDATION_CONFIG", value: `{"management_project_id":"agora-management-test","workload_project_id":"agora-production-test","region":"europe-west1","SERVICE_PROJECTS":{"json-keys":"agora-json-keys-test"}}`},
		{name: "NullLegacyProject", variable: "FOUNDATION_CONFIG", value: `{"management_project_id":"agora-management-test","workload_project_id":null,"region":"europe-west1","service_projects":{"json-keys":"agora-json-keys-test"}}`},
		{name: "LegacyProjectReused", variable: "FOUNDATION_CONFIG", value: `{"management_project_id":"agora-management-test","workload_project_id":"agora-json-keys-test","region":"europe-west1","service_projects":{"json-keys":"agora-json-keys-test"}}`},
		{name: "MissingRegistration", variable: "FOUNDATION_CONFIG", value: `{}`},
		{name: "MissingConfig", variable: "SERVICE_FOUNDATION_CONFIG", value: `{}`},
		{name: "Inactive", variable: "SERVICE_FOUNDATIONS_ENABLED", value: "false"},
		{name: "WrongPublishedManagement", variable: "MANAGEMENT_PROJECT_ID", value: "agora-peer-test"},
		{name: "DuplicateProject", variable: "FOUNDATION_CONFIG", value: `{"management_project_id":"agora-management-test","workload_project_id":"agora-production-test","region":"europe-west1","service_projects":{"json-keys":"agora-json-keys-test","authentication":"agora-json-keys-test"}}`},
		{name: "LegacyServiceChoice", root: "foundation", service: "json-keys"},
		{name: "UnknownRoot", root: "release"},
		{name: "MissingOperation", variable: "FOUNDATION_OPERATION"},
		{name: "UnknownOperation", variable: "FOUNDATION_OPERATION", value: "destroy"},
		{name: "WrongPromotionRoot", variable: "FOUNDATION_OPERATION", value: "promote-images"},
		{name: "UnexpectedPlanID", variable: "FOUNDATION_PLAN_ID", value: "123-1"},
		{name: "MissingApplyPlan", variable: "FOUNDATION_OPERATION", value: "apply"},
		{name: "UnexpectedRecoveryGeneration", variable: "FOUNDATION_GUARD_GENERATION", value: "42"},
		{name: "UnexpectedRecoveryConfirmation", variable: "FOUNDATION_CONFIRM", value: "FINISH json-keys 42"},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			root, service := testCase.root, testCase.service
			if root == "" {
				root = "service-foundation"
			}
			if service == "" {
				service = "json-keys"
			}
			bucket := "agora-management-test-123-tofu-state"
			selected := map[string]string{
				"project_id": "agora-" + service + "-test", "management_project_id": "agora-management-test",
				"state_bucket": bucket, "region": "europe-west1", "service": service,
			}
			if testCase.field != "" {
				selected[testCase.field] = testCase.value
			}
			if testCase.name == "CaseSensitiveProject" {
				selected["PROJECT_ID"] = "agora-json-keys-test"
			}
			data, err := json.Marshal(map[string]any{service: selected})
			require.NoError(t, err)
			env := map[string]string{
				"FOUNDATION_OPERATION":        "plan",
				"SERVICE_FOUNDATIONS_ENABLED": "true",
				"BOOTSTRAP_CONFIG":            `{}`, "MANAGEMENT_PROJECT_ID": "agora-management-test", "STATE_BUCKET": bucket,
				"FOUNDATION_CONFIG":         `{"management_project_id":"agora-management-test","workload_project_id":"agora-production-test","region":"europe-west1","service_projects":{"json-keys":"agora-json-keys-test","authentication":"agora-authentication-test"}}`,
				"SERVICE_FOUNDATION_CONFIG": string(data),
			}
			if testCase.variable != "" {
				env[testCase.variable] = testCase.value
			}
			getenv := func(key string) string { return env[key] }
			file := filepath.Join(t.TempDir(), "selected.json")
			var output, diagnostic bytes.Buffer
			code := workflow.FoundationInputs([]string{"prepare", root, service, file}, getenv, &output, &diagnostic)
			require.Equal(t, testCase.valid, code == 0, diagnostic.String())
			if !testCase.valid {
				require.NoFileExists(t, file)
				require.Empty(t, output.String())
				return
			}
			info, err := os.Stat(file)
			require.NoError(t, err)
			require.Equal(t, os.FileMode(0o600), info.Mode().Perm())
			if root == "service-foundation" {
				suffix := "services/" + selected["project_id"]
				require.Equal(t, "file="+file+"\nstate_suffix="+suffix+"\n", output.String())
				for _, scope := range []string{suffix, "services/agora-peer-test", "recovery/agora-json-keys-test", ""} {
					output.Reset()
					code = workflow.FoundationInputs([]string{"check", file, bucket, scope}, getenv, &output, &diagnostic)
					require.Equal(t, scope == suffix, code == 0)
					require.Empty(t, output.String())
				}
			}
			// Reusing a path cannot silently replace a previous selection.
			require.NotZero(t, workflow.FoundationInputs([]string{"prepare", root, service, file}, getenv, &output, &diagnostic))
			require.NotContains(t, diagnostic.String(), "agora-")
		})
	}
}

func TestFinishOperationInputs(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, root, variable, value string
		valid                       bool
	}{
		{name: "Success", valid: true},
		{name: "ApplyRootNotAllowed", root: "service-foundation"},
		{name: "JobRootNotAllowed", root: "service-release"},
		{name: "Inactive", variable: "SERVICE_OPERATION_RECOVERY_ENABLED"},
		{name: "Unregistered", variable: "FOUNDATION_CONFIG", value: `{}`},
		{name: "WrongWorkflow", variable: "GITHUB_WORKFLOW_REF", value: "a-novel/infra/.github/workflows/drift.yaml@refs/heads/master"},
		{name: "WrongEvent", variable: "GITHUB_EVENT_NAME", value: "push"},
		{name: "MissingGeneration", variable: "FOUNDATION_GUARD_GENERATION"},
		{name: "MissingConfirmation", variable: "FOUNDATION_CONFIRM"},
		{name: "UnexpectedPlan", variable: "FOUNDATION_PLAN_ID", value: "123-1"},
		{name: "LegacyCommand", variable: "FOUNDATION_OPERATION", value: "finish-apply"},
		{name: "PlanCannotFinish", variable: "FOUNDATION_OPERATION", value: "plan"},
		{name: "PlanCannotReplaceGeneration", variable: "FOUNDATION_GUARD_GENERATION", value: "123-1"},
		{name: "LegacyRoot", root: "foundation"},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			root := testCase.root
			if root == "" {
				root = "none"
			}
			env := map[string]string{
				"FOUNDATION_OPERATION": "finish-operation", "FOUNDATION_GUARD_GENERATION": "42", "FOUNDATION_CONFIRM": "FINISH json-keys 42",
				"SERVICE_OPERATION_RECOVERY_ENABLED": "true", "GITHUB_EVENT_NAME": "workflow_dispatch",
				"GITHUB_WORKFLOW_REF":   "a-novel/infra/.github/workflows/foundation.yaml@refs/heads/master",
				"MANAGEMENT_PROJECT_ID": "agora-management-test", "STATE_BUCKET": "agora-management-test-123-tofu-state",
				"FOUNDATION_CONFIG": `{"management_project_id":"agora-management-test","workload_project_id":"agora-production-test","region":"europe-west1","service_projects":{"json-keys":"agora-json-keys-test"}}`,
			}
			if testCase.variable != "" {
				env[testCase.variable] = testCase.value
			}
			file := filepath.Join(t.TempDir(), "unused.json")
			var output, diagnostic bytes.Buffer
			code := workflow.FoundationInputs([]string{"prepare", root, "json-keys", file}, func(key string) string { return env[key] }, &output, &diagnostic)
			require.Equal(t, testCase.valid, code == 0, diagnostic.String())
			want := ""
			if testCase.valid {
				want = "project=agora-json-keys-test\n"
			}
			require.Equal(t, want, output.String())
			require.NoFileExists(t, file, "finishing must not compile new bootstrap inputs")
		})
	}
}
