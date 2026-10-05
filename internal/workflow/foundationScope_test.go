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

func TestSharedFoundationScope(t *testing.T) {
	t.Parallel()
	for _, service := range []string{"json-keys", "authentication"} {
		for _, zone := range []string{"private", "public-api"} {
			for _, testCase := range []struct {
				name, field string
				value       any
				valid       bool
			}{
				{name: "Prerequisites", valid: true},
				{name: "JobsOff", field: "manage_job_access", value: false, valid: true},
				{name: "DatabaseUnset", field: "database", valid: true},
				{name: "HandoffUnset", field: "database_handoff", valid: true},
				{name: "Handoff", field: "database_handoff", value: map[string]any{"private_project_id": "agora-private-test"}, valid: true},
				{name: "PeerHandoff", field: "database_handoff", value: map[string]any{"private_project_id": "agora-peer-test"}},
				{name: "APIHandoff", field: "database_handoff", value: map[string]any{"private_project_id": "agora-api-test"}},
				{name: "MissingHandoffProject", field: "database_handoff", value: map[string]any{}},
				{name: "InvalidHandoff", field: "database_handoff", value: "invalid"},
				{name: "PeerProject", field: "project_id", value: "agora-peer-test"},
				{name: "PeerRegion", field: "region", value: "us-central1"},
				{name: "PeerManagement", field: "management_project_id", value: "agora-peer-test"},
				{name: "PeerBucket", field: "state_bucket", value: "agora-peer-test-123-tofu-state"},
				{name: "Platform", field: "zone", value: "public"},
				{name: "EmptyZone", field: "zone", value: ""},
				{name: "UppercaseZone", field: "zone", value: "PRIVATE"},
				{name: "UnregisteredService", field: "service", value: "peer"},
				{name: "Database", field: "database", value: map[string]any{}},
				{name: "DatabaseRuntime", field: "database_runtime", value: map[string]any{}},
				{name: "Repository", field: "pgbackrest_repository", value: map[string]any{}},
				{name: "Rollout", field: "rollout", value: map[string]any{}},
				{name: "Jobs", field: "manage_job_access", value: true},
				{name: "NullJobs", field: "manage_job_access"},
			} {
				t.Run(service+"/"+zone+"/"+testCase.name, func(t *testing.T) {
					t.Parallel()
					bucket, project := "agora-management-test-123-tofu-state", "agora-private-test"
					if zone == "public-api" {
						project = "agora-api-test"
					}
					config := map[string]any{
						"service": service, "zone": zone, "project_id": project, "region": "europe-west1",
						"management_project_id": "agora-management-test", "state_bucket": bucket,
					}
					if testCase.field != "" {
						config[testCase.field] = testCase.value
					}
					data, err := json.Marshal(config)
					require.NoError(t, err)
					configs, err := json.Marshal(map[string]any{service: config})
					require.NoError(t, err)
					env := sharedFoundationEnvironment()
					env["FOUNDATION_OPERATION"], env["SERVICE_FOUNDATIONS_ENABLED"] = "plan", "true"
					env["STATE_BUCKET"], env["SERVICE_FOUNDATION_CONFIG"] = bucket, string(configs)
					getenv := func(key string) string { return env[key] }
					scope, err := workflow.FoundationScope(data, getenv, bucket)
					require.Equal(t, testCase.valid, err == nil)
					if testCase.valid {
						require.Equal(t, "workloads/production/"+zone+"/"+project+"/"+service, scope)
					}
					file := filepath.Join(t.TempDir(), "inputs.json")
					var out, diagnostic bytes.Buffer
					code := workflow.FoundationInputs([]string{"prepare", "service-foundation", service, file}, getenv, &out, &diagnostic)
					require.Equal(t, testCase.valid, code == 0, diagnostic.String())
					if !testCase.valid {
						require.NoFileExists(t, file)
						return
					}
					require.Equal(t, "file="+file+"\nstate_suffix="+scope+"\n", out.String())
					stored, err := os.ReadFile(file)
					require.NoError(t, err)
					require.Equal(t, data, stored)
					require.Zero(t, workflow.FoundationInputs([]string{"check-foundation", file, bucket, scope}, getenv, &out, &diagnostic))
					require.NotZero(t, workflow.FoundationInputs([]string{"check", file, bucket, scope}, getenv, &out, &diagnostic), "runtime writers remain blocked")
					env["SERVICE_JOB_BOOTSTRAP_ENABLED"], env["SERVICE_JOB_BOOTSTRAP_CONFIG"] = "true", string(configs)
					require.NotZero(t, workflow.FoundationInputs([]string{"prepare", "service-release", service, filepath.Join(t.TempDir(), "jobs.json")}, getenv, &out, &diagnostic))
				})
			}
		}
	}
}

func TestSharedOperationScopes(t *testing.T) {
	t.Parallel()
	env := sharedFoundationEnvironment()
	env["STATE_BUCKET"] = "agora-management-test-123-tofu-state"
	getenv := func(key string) string { return env[key] }
	scopes, err := workflow.OperationScopes(getenv, env["STATE_BUCKET"])
	require.NoError(t, err)
	require.Equal(t, map[string]string{
		"workloads/production/json-keys": "json-keys", "workloads/production/authentication": "authentication",
	}, scopes)
	for _, service := range []string{"json-keys", "authentication"} {
		var out, diagnostic bytes.Buffer
		require.Zero(t, workflow.ObservationInputs([]string{"inspect-operation", service}, getenv, &out, &diagnostic))
		require.Equal(t, "project=workloads/production/"+service+"\n", out.String())
		env["SERVICE_OPERATION_RECOVERY_ENABLED"], env["GITHUB_EVENT_NAME"] = "true", "workflow_dispatch"
		env["GITHUB_WORKFLOW_REF"] = "a-novel/infra/.github/workflows/foundation.yaml@refs/heads/master"
		scope, err := workflow.FinishOperationProject([]string{service, "42", "FINISH " + service + " 42"}, getenv)
		require.NoError(t, err)
		require.Equal(t, "workloads/production/"+service, scope)
	}
}

func TestSharedRepositoryScope(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, field string
		value       any
		valid       bool
	}{
		{name: "Success/Default", valid: true},
		{name: "Success/Micro", field: "machine_type", value: "e2-micro", valid: true},
		{name: "Success/NullRuntime", field: "runtime", valid: true},
		{name: "Error/Runtime", field: "runtime", value: map[string]any{}},
		{name: "Error/LargerHost", field: "machine_type", value: "e2-small"},
		{name: "Error/EmptyMachine", field: "machine_type", value: ""},
		{name: "Error/MalformedMachine", field: "machine_type", value: 1},
		{name: "Error/NoPlacement", field: "placement"},
		{name: "Error/MalformedPlacement", field: "placement", value: "invalid"},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			repository := map[string]any{"placement": map[string]string{"zone": "europe-west1-b"}}
			if testCase.field != "" {
				repository[testCase.field] = testCase.value
			}
			bucket := "agora-management-test-123-tofu-state"
			config := map[string]any{
				"service": "json-keys", "zone": "private", "project_id": "agora-private-test", "region": "europe-west1",
				"management_project_id": "agora-management-test", "state_bucket": bucket,
				"database_handoff":      map[string]any{"private_project_id": "agora-private-test"},
				"pgbackrest_repository": repository,
			}
			env := sharedFoundationEnvironment()
			getenv := func(key string) string { return env[key] }
			data, err := json.Marshal(config)
			require.NoError(t, err)
			_, err = workflow.FoundationScope(data, getenv, bucket)
			require.Equal(t, testCase.valid, err == nil)
			if !testCase.valid {
				return
			}
			for field, value := range map[string]any{
				"zone": "public-api", "service": "authentication", "database_handoff": nil,
				"database": map[string]any{}, "database_runtime": map[string]any{},
			} {
				original := config[field]
				config[field] = value
				data, err = json.Marshal(config)
				require.NoError(t, err)
				_, err = workflow.FoundationScope(data, getenv, bucket)
				require.Error(t, err, field)
				config[field] = original
			}
		})
	}
}

func TestSharedDatabaseHandoff(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, service, zone string
		field               string
		value               any
		valid               bool
	}{
		{name: "PrivateJSONKeys", service: "json-keys", zone: "private", valid: true},
		{name: "JSONKeysAPI", service: "json-keys", zone: "public-api", valid: true},
		{name: "AuthenticationAPI", service: "authentication", zone: "public-api", valid: true},
		{name: "PrivateAuthentication", service: "authentication", zone: "private", valid: true},
		{name: "MissingHandoff", field: "database_handoff", valid: true},
		{name: "PeerHandoff", field: "database_handoff", value: map[string]any{"private_project_id": "agora-peer-test"}},
		{name: "InvalidRollout", field: "rollout", value: "invalid"},
		{name: "MissingProbe", field: "rollout", value: map[string]any{}},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			service, zone, project := "json-keys", "public-api", "agora-api-test"
			if testCase.service != "" {
				service, zone = testCase.service, testCase.zone
			}
			if zone == "private" {
				project = "agora-private-test"
			}
			bucket := "agora-management-test-123-tofu-state"
			config := map[string]any{
				"service": service, "zone": zone, "project_id": project, "region": "europe-west1",
				"management_project_id": "agora-management-test", "state_bucket": bucket,
				"database_handoff": map[string]any{"private_project_id": "agora-private-test"},
			}
			if testCase.field != "" {
				config[testCase.field] = testCase.value
			}
			data, err := json.Marshal(config)
			require.NoError(t, err)
			env := sharedFoundationEnvironment()
			getenv := func(key string) string { return env[key] }
			scope, err := workflow.FoundationScope(data, getenv, bucket)
			require.Equal(t, testCase.valid, err == nil)
			if testCase.valid {
				require.Equal(t, "workloads/production/"+zone+"/"+project+"/"+service, scope)
			}
			_, err = workflow.ServiceScope(data, getenv, bucket)
			require.Error(t, err, "foundation setup does not admit shared runtime writers")
		})
	}
}

func sharedFoundationEnvironment() map[string]string {
	return map[string]string{
		"MANAGEMENT_PROJECT_ID": "agora-management-test",
		"FOUNDATION_CONFIG": `{"management_project_id":"agora-management-test","workload_project_id":"agora-private-test",
		"public_api_project_id":"agora-api-test","region":"europe-west1","shared_vpc_enabled":true,
		"service_release_zones":{"json-keys":["private","public-api"],"authentication":["private","public-api"]}}`,
	}
}
