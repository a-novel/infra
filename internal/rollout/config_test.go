package rollout_test

import (
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/a-novel/infra/internal/rollout"
)

func TestFromEnv(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, key, value string
		valid            bool
	}{
		{name: "Success/ProjectID", valid: true},
		{name: "Success/ProjectNumber", key: "CLOUD_RUN_PROJECT", value: "123456", valid: true},
		{name: "Error/PeerProject", key: "CLOUD_RUN_PROJECT", value: "peer"},
		{name: "Error/PeerPipeline", key: "CLOUD_DEPLOY_DELIVERY_PIPELINE", value: "authentication"},
		{name: "Error/Phase", key: "CLOUD_DEPLOY_PHASE", value: "canary-50"},
		{name: "Error/PathTraversal", key: "CLOUD_DEPLOY_RELEASE", value: "../other"},
		{name: "Error/FloatingVerifier", key: "EXPECTED_VERIFIER_IMAGE", value: "verifier:latest"},
		{name: "Error/PeerProbe", key: "EXPECTED_PROBE_ACCOUNT", value: "runtime@peer.iam.gserviceaccount.com"},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			config, _, _ := fixture(t)
			env := map[string]string{
				"EXPECTED_PROJECT_ID": config.ProjectID, "CLOUD_DEPLOY_PROJECT_ID": config.ProjectID, "CLOUD_RUN_PROJECT": config.ProjectID,
				"CLOUD_DEPLOY_PROJECT": config.ProjectNumber, "EXPECTED_REGION": config.Region,
				"CLOUD_RUN_LOCATION": config.Region, "CLOUD_DEPLOY_LOCATION": config.Region,
				"EXPECTED_SERVICE": config.Service, "CLOUD_RUN_SERVICE": config.Service,
				"CLOUD_DEPLOY_TARGET": config.Service, "CLOUD_DEPLOY_DELIVERY_PIPELINE": config.Service,
				"CLOUD_DEPLOY_RELEASE": config.Release, "CLOUD_DEPLOY_ROLLOUT": config.Rollout,
				"CLOUD_DEPLOY_JOB_RUN": config.JobRun, "CLOUD_RUN_REVISION": config.Revision, "CLOUD_DEPLOY_PHASE": config.Phase,
				"EXPECTED_PROBE_ACCOUNT": config.ProbeAccount, "EXPECTED_VERIFIER_IMAGE": config.VerifierImage,
				"EXPECTED_PROBE_NETWORK": config.ProbeNetwork, "EXPECTED_PROBE_SUBNET": config.ProbeSubnet,
			}
			if testCase.key != "" {
				env[testCase.key] = testCase.value
			}
			actual, err := rollout.FromEnv(func(key string) string { return env[key] })
			if testCase.valid {
				require.NoError(t, err)
				require.Equal(t, config, actual)
			} else {
				require.Error(t, err)
			}
		})
	}
}
