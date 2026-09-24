package workflow_test

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/a-novel/infra/internal/workflow"
)

func TestJobBootstrapInputs(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, field string
		value       any
		stage       string
		env         map[string]string
	}{
		{name: "ExactBytes"},
		{name: "Disabled", stage: "prepare", env: map[string]string{"SERVICE_JOB_BOOTSTRAP_ENABLED": ""}},
		{name: "Apply", env: map[string]string{"FOUNDATION_OPERATION": "apply", "FOUNDATION_PLAN_ID": "123-1"}},
		{name: "ImagesOnly", env: map[string]string{"FOUNDATION_OPERATION": "promote-images", "SERVICE_JOB_BOOTSTRAP_ENABLED": ""}},
		{name: "ImagesDisabled", stage: "prepare", env: map[string]string{"FOUNDATION_OPERATION": "promote-images", "SERVICE_IMAGE_PROMOTION_ENABLED": ""}},
		{name: "ImagesWithPlan", stage: "prepare", env: map[string]string{"FOUNDATION_OPERATION": "promote-images", "FOUNDATION_PLAN_ID": "123-1"}},
		{name: "PeerProject", stage: "prepare"},
		{name: "EmbeddedCoordinates", stage: "prepare"},
		{name: "PeerBucket", field: "bucket", value: "peer-bucket", stage: "prepare"},
		{name: "PeerObject", field: "object", value: "foundation/coordinates/peer/data.json", stage: "prepare"},
		{name: "LatestGeneration", field: "generation", value: "latest", stage: "prepare"},
		{name: "NumericGeneration", field: "generation", value: 123456, stage: "prepare"},
		{name: "Schema", field: "schema_version", value: 2, stage: "prepare"},
		{name: "UnknownHash", field: "sha256", value: "", stage: "prepare"},
		{name: "ChangedBytes", stage: "bind"},
		{name: "RevokedRegistration", stage: "bind"},
		{name: "RevokedActivation", stage: "bind"},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			coordinates := "{\n  \"private\": \"fixture-private-value\"\n}\n"
			hash := fmt.Sprintf("%x", sha256.Sum256([]byte(coordinates)))
			bucket := "agora-management-test-123-tofu-state"
			object := "foundation/coordinates/agora-json-keys-test/" + hash + ".json"
			reference := map[string]any{"schema_version": 1, "bucket": bucket, "object": object, "generation": "123456", "sha256": hash}
			selected := map[string]any{
				"service": "json-keys", "project_id": "agora-json-keys-test", "region": "europe-west1",
				"state_bucket": bucket, "management_project_id": "agora-management-test", "foundation": reference,
			}
			env := map[string]string{
				"FOUNDATION_OPERATION": "plan", "SERVICE_IMAGE_PROMOTION_ENABLED": "true",
				"SERVICE_JOB_BOOTSTRAP_ENABLED": "true", "STATE_BUCKET": bucket, "MANAGEMENT_PROJECT_ID": "agora-management-test",
				"FOUNDATION_CONFIG": `{"management_project_id":"agora-management-test","workload_project_id":"agora-production-test","region":"europe-west1","service_projects":{"json-keys":"agora-json-keys-test"}}`,
			}
			for key, value := range testCase.env {
				env[key] = value
			}
			if testCase.field != "" {
				reference[testCase.field] = testCase.value
			}
			switch testCase.name {
			case "PeerProject":
				selected["project_id"] = "agora-peer-test"
			case "EmbeddedCoordinates":
				selected["foundation_json"] = coordinates
			}
			data, err := json.Marshal(map[string]any{"json-keys": selected})
			require.NoError(t, err)
			env["SERVICE_JOB_BOOTSTRAP_CONFIG"] = string(data)
			getenv := func(key string) string { return env[key] }
			dir := t.TempDir()
			input, download, output := filepath.Join(dir, "selected.json"), filepath.Join(dir, "coordinates.json"), filepath.Join(dir, "bound.json")
			var stdout, stderr bytes.Buffer
			code := workflow.FoundationInputs([]string{"prepare", "service-release", "json-keys", input}, getenv, &stdout, &stderr)
			if testCase.stage == "prepare" {
				require.Equal(t, 65, code)
				require.NoFileExists(t, input)
				require.Empty(t, stdout.String())
				return
			}
			require.Zero(t, code, stderr.String())
			require.Contains(t, stdout.String(), "foundation_uri=gs://"+bucket+"/"+object+"#123456\n")
			if env["FOUNDATION_OPERATION"] == "promote-images" {
				return // Image publication never hydrates foundation coordinates or creates a plan.
			}
			switch testCase.name {
			case "ChangedBytes":
				coordinates = strings.TrimSpace(coordinates)
			case "RevokedRegistration":
				env["FOUNDATION_CONFIG"] = `{}`
			case "RevokedActivation":
				delete(env, "SERVICE_JOB_BOOTSTRAP_ENABLED")
			}
			require.NoError(t, os.WriteFile(download, []byte(coordinates), 0o600))
			stdout.Reset()
			args := []string{"bind", input, download, output}
			code = workflow.FoundationInputs(args, getenv, &stdout, &stderr)
			require.Equal(t, testCase.stage == "", code == 0, stderr.String())
			require.NotContains(t, stdout.String()+stderr.String(), "fixture-private-value")
			if code != 0 {
				require.NoFileExists(t, output)
				return
			}
			bound, err := os.ReadFile(output)
			require.NoError(t, err)
			require.NoError(t, json.Unmarshal(bound, &selected))
			require.Equal(t, coordinates, selected["foundation_json"])
			require.Equal(t, "file="+output+"\nstate_suffix=services/agora-json-keys-test\n", stdout.String())
			require.Equal(t, 65, workflow.FoundationInputs(args, getenv, &stdout, &stderr), "cannot replace an existing destination")
		})
	}
}
