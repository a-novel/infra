package workflow_test

import (
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/a-novel/infra/internal/workflow"
)

func TestReleaseScopes(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, key string
		value     any
		valid     bool
		zones     map[string][]string
	}{
		{name: "Success", valid: true},
		{name: "EmptyRecoveryRegistration", key: "service_recovery_projects", value: map[string]string{}, valid: true},
		{name: "EmptyRepositoryRegistration", key: "pgbackrest_repository_services", value: []string{}, valid: true},
		{name: "PeerManagement", key: "management_project_id", value: "agora-peer-test"},
		{name: "MissingPrivateProject", key: "workload_project_id"},
		{name: "PrivateReusesManagement", key: "workload_project_id", value: "agora-management-test"},
		{name: "InvalidPrivateProject", key: "workload_project_id", value: "../peer"},
		{name: "PublicReusesPrivate", key: "public_project_id", value: "agora-private-test"},
		{name: "PublicReusesManagement", key: "public_project_id", value: "agora-management-test"},
		{name: "MissingPublicProject", key: "public_project_id", valid: true},
		{name: "MissingAPIProject", key: "public_api_project_id"},
		{name: "APIReusesPrivate", key: "public_api_project_id", value: "agora-private-test"},
		{name: "APIReusesManagement", key: "public_api_project_id", value: "agora-management-test"},
		{name: "APIReusesPlatform", key: "public_api_project_id", value: "agora-public-test"},
		{name: "InvalidAPIProject", key: "public_api_project_id", value: 123},
		{name: "PlatformServiceRejected", key: "service_release_zones", value: map[string][]string{"json-keys": {"public"}}},
		{name: "InvalidRegion", key: "region", value: "europe-west1/peer"},
		{name: "NullZones", key: "service_release_zones"},
		{name: "UnknownService", key: "service_release_zones", value: map[string][]string{"peer": {"private"}}},
		{name: "EmptyZones", key: "service_release_zones", value: map[string][]string{"json-keys": {}}},
		{name: "NullZoneSet", key: "service_release_zones", value: map[string][]string{"json-keys": nil}},
		{name: "DuplicateZones", key: "service_release_zones", value: map[string][]string{"json-keys": {"private", "private"}}},
		{name: "UnknownZone", key: "service_release_zones", value: map[string][]string{"json-keys": {"admin"}}},
		{name: "NullSharedVPC", key: "shared_vpc_enabled"},
		{name: "InactiveSharedVPC", key: "shared_vpc_enabled", value: false},
		{name: "RecoveryMode", key: "recovery_mode", value: true},
		{name: "NullDedicatedProjects", key: "service_projects"},
		{name: "DedicatedProjects", key: "service_projects", value: map[string]string{"json-keys": "agora-json-keys-test"}},
		{name: "RecoveryProjects", key: "service_recovery_projects", value: map[string]string{"agora-recovery-test": "json-keys"}},
		{name: "PrivateRecovery", key: "service_recovery_projects", value: map[string]string{"a-novel-recovery-test": "json-keys"}, valid: true},
		{name: "PublicOnlyRecovery", key: "service_recovery_projects", value: map[string]string{"a-novel-recovery-test": "json-keys"}, zones: map[string][]string{"json-keys": {"public-api"}}},
		{name: "PeerRecovery", key: "service_recovery_projects", value: map[string]string{"a-novel-recovery-test": "authentication"}},
		{name: "NullRecoveryProjects", key: "service_recovery_projects"},
		{name: "RepositoryServices", key: "pgbackrest_repository_services", value: []string{"json-keys"}, valid: true},
		{name: "AuthenticationRepository", key: "pgbackrest_repository_services", value: []string{"authentication"}, valid: true},
		{name: "BothRepositories", key: "pgbackrest_repository_services", value: []string{"json-keys", "authentication"}, valid: true},
		{name: "PeerRepository", key: "pgbackrest_repository_services", value: []string{"peer"}},
		{name: "PublicRepository", key: "pgbackrest_repository_services", value: []string{"json-keys"}, zones: map[string][]string{"json-keys": {"public-api"}}},
		{name: "UnregisteredRepository", key: "pgbackrest_repository_services", value: []string{"json-keys"}, zones: map[string][]string{"authentication": {"private"}}},
		{name: "NullRepositoryServices", key: "pgbackrest_repository_services"},
		{name: "WrongRepositoryType", key: "pgbackrest_repository_services", value: map[string]string{}},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			registration := map[string]any{
				"management_project_id": "agora-management-test", "workload_project_id": "agora-private-test",
				"public_project_id": "agora-public-test", "public_api_project_id": "agora-api-test", "region": "europe-west1", "shared_vpc_enabled": true,
				"service_release_zones": map[string][]string{"json-keys": {"private", "public-api"}, "authentication": {"private"}},
			}
			if testCase.key != "" {
				registration[testCase.key] = testCase.value
			}
			if testCase.zones != nil {
				registration["service_release_zones"] = testCase.zones
			}
			data, err := json.Marshal(registration)
			require.NoError(t, err)
			env := map[string]string{"FOUNDATION_CONFIG": string(data), "MANAGEMENT_PROJECT_ID": "agora-management-test"}
			getenv := func(key string) string { return env[key] }
			scopes, err := workflow.ReleaseScopes(getenv, "agora-management-test-123-tofu-state")
			if !testCase.valid {
				require.Error(t, err)
				require.Nil(t, scopes)
				return
			}
			require.NoError(t, err)
			require.Equal(t, map[string]string{
				"workloads/production/private/agora-private-test/json-keys":      "json-keys",
				"workloads/production/private/agora-private-test/authentication": "authentication",
				"workloads/production/public-api/agora-api-test/json-keys":       "json-keys",
			}, scopes)
			_, err = workflow.ReleaseScopes(getenv, "agora-peer-test-123-tofu-state")
			require.Error(t, err)
			legacy, err := workflow.ServiceScopes(getenv, "agora-management-test-123-tofu-state")
			require.NoError(t, err)
			require.Empty(t, legacy, "release boundary enrollment must not enroll database writers")
		})
	}
}
