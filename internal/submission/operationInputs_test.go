package submission_test

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/a-novel/infra/internal/submission"
)

func TestOperationInputs(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, env, value, field string
	}{
		{name: "Success"},
		{name: "Disabled", env: "SERVICE_NATIVE_RELEASE_ENABLED"},
		{name: "UntrustedWorkflow", env: "GITHUB_WORKFLOW_REF", value: "pull_request.yaml"},
		{name: "StaleCommit", env: "GITHUB_SHA", value: strings.Repeat("0", 40)},
		{name: "UnregisteredProject", field: "project_id", value: "other-project"},
		{name: "UnboundRegion", field: "region", value: "europe-west2"},
		{name: "MissingPredecessor", field: "predecessor"},
		{name: "UnknownInput", field: "override", value: "unsafe"},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			request := fixture(t)
			job, _ := migrationFixture(t, request.Release)
			config, env := operationFixture(t, request, job, job)
			if testCase.field != "" {
				config[testCase.field] = testCase.value
			}
			if testCase.env != "" {
				env[testCase.env] = testCase.value
			}
			data := encodeOperation(t, config)
			env["SERVICE_RELEASE_OPERATION_JSON"] = string(data)
			file := filepath.Join(t.TempDir(), "private.json")
			var output bytes.Buffer
			code := submission.Operation(t.Context(), []string{"prepare", file}, func(key string) string { return env[key] }, nil, nil, &output, &output)
			if testCase.name != "Success" {
				require.Equal(t, 1, code)
				_, err := os.Stat(file)
				require.ErrorIs(t, err, os.ErrNotExist)
				return
			}
			require.Zero(t, code, "%s", &output)
			stored, err := os.ReadFile(file)
			require.NoError(t, err)
			require.JSONEq(t, string(data), string(stored))
			info, err := os.Stat(file)
			require.NoError(t, err)
			require.Equal(t, os.FileMode(0o600), info.Mode().Perm())
			require.Equal(t, 1, submission.Operation(t.Context(), []string{"prepare", file}, func(key string) string { return env[key] }, nil, nil, &output, &output), "preparation must never overwrite")
		})
	}
}
