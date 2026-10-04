package workflow_test

import (
	"bytes"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/a-novel/infra/internal/workflow"
)

func TestOperationInspectionInputs(t *testing.T) {
	t.Parallel()
	const registration = `{"management_project_id":"agora-management-test","workload_project_id":"agora-production-test","region":"europe-west1","service_projects":{"json-keys":"agora-json-keys-test","authentication":"agora-authentication-test"}}`
	for _, testCase := range []struct {
		name, service, registration, bucket, want string
	}{
		{"JSONKeys", "json-keys", registration, "agora-management-test-123-tofu-state", "project=agora-json-keys-test\n"},
		{"Authentication", "authentication", registration, "agora-management-test-123-tofu-state", "project=agora-authentication-test\n"},
		{"Unregistered", "json-keys", strings.Replace(registration, `"json-keys":"agora-json-keys-test",`, "", 1), "agora-management-test-123-tofu-state", ""},
		{"MissingRegistration", "json-keys", "", "agora-management-test-123-tofu-state", ""},
		{"PeerBucket", "json-keys", registration, "agora-peer-test-123-tofu-state", ""},
		{"ScopeInjection", "json-keys\nproject=peer", registration, "agora-management-test-123-tofu-state", ""},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			// Mutation flags remain unset: inspection is read-only.
			values := map[string]string{
				"FOUNDATION_CONFIG": testCase.registration, "MANAGEMENT_PROJECT_ID": "agora-management-test", "STATE_BUCKET": testCase.bucket,
			}
			var output, diagnostic bytes.Buffer
			code := workflow.ObservationInputs([]string{"inspect-operation", testCase.service}, func(key string) string { return values[key] }, &output, &diagnostic)
			require.Equal(t, testCase.want != "", code == 0, diagnostic.String())
			require.Equal(t, testCase.want, output.String())
			require.NotContains(t, diagnostic.String(), "agora-")
		})
	}
}
