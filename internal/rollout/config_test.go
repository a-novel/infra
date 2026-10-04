package rollout_test

import (
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/a-novel/infra/internal/rollout"
)

func TestFromEnv(t *testing.T) {
	t.Parallel()
	for _, scope := range []struct{ service, zone string }{
		{"agora-json-keys-grpc", ""},
		{"agora-json-keys-grpc", "private"},
		{"agora-json-keys-rest", "public-api"},
		{"agora-authentication-rest", "public-api"},
	} {
		t.Run(scope.service+"/"+scope.zone, func(t *testing.T) {
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
				{name: "Error/ApplicationAsProbe", key: "EXPECTED_PROBE_ACCOUNT", value: "agora-json-keys-private@agora-json-keys-test.iam.gserviceaccount.com"},
				{name: "Error/PlatformZone", key: "EXPECTED_ZONE", value: "public"},
				{name: "Error/UnknownZone", key: "EXPECTED_ZONE", value: "preprod"},
				{name: "Error/MismatchedNetworkHost", key: "EXPECTED_PROBE_SUBNET", value: "projects/agora-json-keys-test/regions/europe-west1/subnetworks/agora-production"},
			} {
				t.Run(testCase.name, func(t *testing.T) {
					t.Parallel()
					config, _, _ := scopedFixture(t, scope.service, scope.zone)
					env := verificationEnv(t, config)
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
		})
	}
}

func TestSharedVerifierScope(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct{ name, service, zone string }{
		{"Error/PublicWithoutZone", "agora-json-keys-rest", ""},
		{"Error/PrivateREST", "agora-authentication-rest", "private"},
		{"Error/PublicGRPC", "agora-json-keys-grpc", "public-api"},
		{"Error/UnsupportedComponent", "agora-authentication-grpc", "private"},
		{"Error/PeerVerifierRepository", "agora-json-keys-rest", "public-api"},
		{"Error/LegacyVerifierRepository", "agora-json-keys-grpc", "private"},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			config, _, _ := scopedFixture(t, "agora-json-keys-grpc", "private")
			config.Service, config.Zone = testCase.service, testCase.zone
			env := verificationEnv(t, config)
			if testCase.name == "Error/PeerVerifierRepository" {
				env["EXPECTED_PROBE_ACCOUNT"] = "probe-json-keys-api@" + config.ProjectID + ".iam.gserviceaccount.com"
			}
			if testCase.name == "Error/LegacyVerifierRepository" {
				env["EXPECTED_VERIFIER_IMAGE"] = "europe-west1-docker.pkg.dev/" + config.ProjectID + "/agora-tooling/verify@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
			}
			_, err := rollout.FromEnv(func(key string) string { return env[key] })
			require.Error(t, err)
		})
	}
}
