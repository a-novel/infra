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

func TestPublicAPIReleaseScope(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, key string
		value     any
		valid     bool
	}{
		{name: "RegisteredAPI", valid: true},
		{name: "PrivateJobs", key: "zone", value: "private"},
		{name: "Platform", key: "zone", value: "public"},
		{name: "PeerProject", key: "project_id", value: "agora-peer-test"},
		{name: "PeerDatabase", key: "private_project_id", value: "agora-peer-test"},
		{name: "MissingAPI", key: "api"},
		{name: "Jobs", key: "images", value: map[string]string{"migrations": "unused"}},
		{name: "MissingJobsInventory", key: "images"},
		{name: "DatabaseCreation", key: "database", value: map[string]any{}},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			bucket := "agora-management-test-123-tofu-state"
			config := map[string]any{
				"service": "authentication", "zone": "public-api", "project_id": "agora-api-test",
				"private_project_id": "agora-private-test", "management_project_id": "agora-management-test",
				"state_bucket": bucket, "region": "europe-west1", "images": map[string]string{},
				"api": map[string]string{"image": "fixture"},
			}
			if testCase.key != "" {
				config[testCase.key] = testCase.value
			}
			data, err := json.Marshal(config)
			require.NoError(t, err)
			file := filepath.Join(t.TempDir(), "inputs.json")
			require.NoError(t, os.WriteFile(file, data, 0o600))
			env := sharedFoundationEnvironment()
			var out, diagnostic bytes.Buffer
			code := workflow.FoundationInputs([]string{
				"check-release", file, bucket,
				"workloads/production/public-api/agora-api-test/authentication",
			},
				func(key string) string { return env[key] }, &out, &diagnostic)
			require.Equal(t, testCase.valid, code == 0, diagnostic.String())
		})
	}
}

func TestPrivateJobReleaseScope(t *testing.T) {
	t.Parallel()
	for _, service := range []string{"authentication", "json-keys"} {
		for _, testCase := range []struct {
			name, key string
			value     any
			valid     bool
		}{
			{name: "RegisteredJobs", valid: true},
			{name: "API", key: "api", value: map[string]string{"image": "fixture"}},
			{name: "PeerProject", key: "project_id", value: "agora-peer-test"},
			{name: "PeerRegion", key: "region", value: "us-central1"},
			{name: "PublicZone", key: "zone", value: "public"},
			{name: "DatabaseCreation", key: "database", value: map[string]any{}},
			{name: "RepositoryCreation", key: "pgbackrest_repository", value: map[string]any{}},
		} {
			t.Run(service+"/"+testCase.name, func(t *testing.T) {
				t.Parallel()
				bucket := "agora-management-test-123-tofu-state"
				config := map[string]any{
					"service": service, "zone": "private", "project_id": "agora-private-test",
					"management_project_id": "agora-management-test", "state_bucket": bucket, "region": "europe-west1",
				}
				if testCase.key != "" {
					config[testCase.key] = testCase.value
				}
				data, err := json.Marshal(config)
				require.NoError(t, err)
				file := filepath.Join(t.TempDir(), "inputs.json")
				require.NoError(t, os.WriteFile(file, data, 0o600))
				env := sharedFoundationEnvironment()
				var out, diagnostic bytes.Buffer
				code := workflow.FoundationInputs([]string{
					"check-release", file, bucket, "workloads/production/private/agora-private-test/" + service,
				}, func(key string) string { return env[key] }, &out, &diagnostic)
				require.Equal(t, testCase.valid, code == 0, diagnostic.String())
			})
		}
	}
}
