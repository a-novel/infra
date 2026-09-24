package workflow_test

import (
	"bytes"
	"io"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/a-novel/infra/internal/workflow"
)

func TestObservationInputs(t *testing.T) {
	t.Parallel()
	const parent = "projects/123456/locations/europe-west1/deliveryPipelines/agora-json-keys-grpc"
	for _, testCase := range []struct {
		name, enabled, parent string
		args                  []string
		valid                 bool
	}{
		{"Success", "true", parent, []string{"json-keys", "release-123", "production"}, true},
		{"Error/Disabled", "", parent, []string{"json-keys", "release-123", "production"}, false},
		{"Error/MissingScope", "true", "", []string{"json-keys", "release-123", "production"}, false},
		{"Error/ProjectID", "true", strings.Replace(parent, "123456", "service-project", 1), []string{"json-keys", "release-123", "production"}, false},
		{"Error/PeerPipeline", "true", strings.Replace(parent, "agora-json-keys-grpc", "agora-authentication-rest", 1), []string{"json-keys", "release-123", "production"}, false},
		{"Error/ScopeInjection", "true", parent + "\nrollout=other", []string{"json-keys", "release-123", "production"}, false},
		{"Error/PeerService", "true", parent, []string{"authentication", "release-123", "production"}, false},
		{"Error/ResourcePath", "true", parent, []string{"json-keys", parent + "/releases/release-123", "production"}, false},
		{"Error/IDInjection", "true", parent, []string{"json-keys", "release-123", "production\n"}, false},
		{"Error/MissingIDs", "true", parent, nil, false},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			var output bytes.Buffer
			values := map[string]string{"SERVICE_ROLLOUT_OBSERVATION_ENABLED": testCase.enabled, "GCP_JSON_KEYS_ROLLOUT_PARENT": testCase.parent}
			code := workflow.ObservationInputs(testCase.args, func(key string) string { return values[key] }, &output, io.Discard)
			want := ""
			if testCase.valid {
				want = "rollout=" + parent + "/releases/release-123/rollouts/production\n"
			}
			require.Equal(t, testCase.valid, code == 0)
			require.Equal(t, want, output.String())
		})
	}
}
