package rollout_test

import (
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/a-novel/infra/internal/rollout"
)

func TestProbe(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, service, audience, phase, url string
		valid                               bool
	}{
		{"Success/Legacy", "", "https://agora-json-keys-grpc-example-ew.a.run.app", "stable", "https://agora-json-keys-grpc-example-ew.a.run.app", true},
		{"Success/Private", "agora-json-keys-grpc", "https://agora-json-keys-grpc-example-ew.a.run.app", "canary-0", "https://candidate---agora-json-keys-grpc-example-ew.a.run.app", true},
		{"Success/JSONKeysREST", "agora-json-keys-rest", "https://agora-json-keys-rest-example-ew.a.run.app", "stable", "https://agora-json-keys-rest-example-ew.a.run.app", true},
		{"Success/AuthenticationREST", "agora-authentication-rest", "https://agora-authentication-rest-example-ew.a.run.app", "canary-0", "https://candidate---agora-authentication-rest-example-ew.a.run.app", true},
		{"Error/Peer", "agora-json-keys-rest", "https://agora-authentication-rest-example-ew.a.run.app", "stable", "https://agora-authentication-rest-example-ew.a.run.app", false},
		{"Error/Unsupported", "agora-authentication-grpc", "https://agora-authentication-grpc-example-ew.a.run.app", "stable", "https://agora-authentication-grpc-example-ew.a.run.app", false},
		{"Error/MissingRESTBinding", "", "https://agora-json-keys-rest-example-ew.a.run.app", "stable", "https://agora-json-keys-rest-example-ew.a.run.app", false},
		{"Error/Metadata", "agora-json-keys-rest", "http://metadata.google.internal", "stable", "http://metadata.google.internal", false},
		{"Error/StaleServing", "agora-json-keys-rest", "https://agora-json-keys-rest-example-ew.a.run.app", "canary-0", "https://agora-json-keys-rest-example-ew.a.run.app", false},
		{"Error/UnexpectedPhase", "agora-json-keys-rest", "https://agora-json-keys-rest-example-ew.a.run.app", "canary-50", "https://agora-json-keys-rest-example-ew.a.run.app", false},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			probe := rollout.Probe{Service: testCase.service, Audience: testCase.audience, URL: testCase.url, Phase: testCase.phase, Revision: "revision", Image: "digest", JobRun: "verify"}
			if testCase.valid {
				require.NoError(t, probe.Validate())
			} else {
				require.Error(t, probe.Validate())
			}
		})
	}
}
