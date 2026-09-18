package release_test

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestCompilerRecovery(t *testing.T) {
	t.Parallel()
	for _, name := range []string{"Release", "Foundation", "ServiceProjects", "FoundationServiceProjects", "ServiceProjectTarget", "InvalidServiceProjects", "InvalidServiceProjectID", "LegacyHost", "CustomQuotas", "SourceTarget", "ManagementTarget", "WrongSource", "WrongOutputProject", "MissingOutput", "BadAttempt", "ForeignImage", "DuplicateImage"} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			fixture := setup(t)
			config := object{}
			for _, key := range []string{"management_project_id", "workload_project_id", "region", "backup_bucket_name"} {
				config[key] = fixture.config[key]
			}
			state := object{
				"workload_project_id": object{"value": "agora-recovery-test"},
				"network":             object{"value": object{"network_id": "recovery-network", "subnet_id": "recovery-subnet"}},
				"database_hosts": object{"value": object{
					"authentication": object{"private_ip": "10.20.0.8", "data_disk": object{"id": "2001"}},
					"json_keys":      object{"private_ip": "10.20.0.9", "data_disk": object{"id": json.Number("12345678901234567890")}},
				}},
				"cloud_run_invocation_tags": object{"value": fixture.config["cloud_run_invocation_tags"]},
			}
			files := []string{filepath.Join(t.TempDir(), "foundation.json"), fixture.files[2], filepath.Join(t.TempDir(), "outputs.json"), "agora-recovery-test", "1750000000-json-backup-0", "1750000001-auth-backup-0", "release", fixture.files[3]}
			invalid := false
			switch name {
			case "Foundation":
				files[6] = "foundation"
			case "ServiceProjects", "FoundationServiceProjects", "ServiceProjectTarget":
				config["service_projects"] = object{"json-keys": "json-keys-project-prod", "authentication": "authentication-prod"}
				if name == "FoundationServiceProjects" {
					files[6] = "foundation"
				}
				if name == "ServiceProjectTarget" {
					files[3] = "json-keys-project-prod"
					files[6] = "foundation"
					invalid = true
				}
			case "InvalidServiceProjects":
				config["service_projects"] = []any{"json-keys-project-prod"}
				invalid = true
			case "InvalidServiceProjectID":
				config["service_projects"] = object{"json-keys": nil}
				invalid = true
			case "LegacyHost":
				delete(section(fixture.receipt, "activeTfvars"), "database_hosts")
				section(fixture.receipt, "activeTfvars")["database_private_ip"] = "10.20.0.99"
			case "CustomQuotas":
				config["compute_cpu_quota"] = 8
			case "SourceTarget":
				files[3] = "agora-production-test"
				invalid = true
			case "ManagementTarget":
				files[3] = "agora-management-test"
				invalid = true
			case "WrongSource":
				config["backup_bucket_name"] = "different-bucket"
				invalid = true
			case "WrongOutputProject":
				section(state, "workload_project_id")["value"] = "different-project"
				invalid = true
			case "MissingOutput":
				delete(state, "database_hosts")
				invalid = true
			case "BadAttempt":
				files[4] = "latest"
				invalid = true
			case "ForeignImage":
				section(fixture.receipt, "activeTfvars", "application_release", "authentication", "images")["rest"] = "europe-west1-docker.pkg.dev/wrong-project/agora-production/rest@sha256:bad"
				invalid = true
			case "DuplicateImage":
				images := section(fixture.receipt, "activeTfvars", "application_release", "authentication", "images")
				images["rest"] = images["init"]
				invalid = true
			}
			write(t, files[0], config)
			write(t, files[1], fixture.receipt)
			write(t, files[2], state)
			err := fixture.compiler.CompileRecovery(files, fixture.identity)
			if invalid {
				require.Error(t, err)
				require.NoDirExists(t, files[7])
				return
			}
			require.NoError(t, err)
			foundation := result(t, fixture, "foundation.tfvars.json")
			require.Equal(t, "agora-recovery-test", foundation["workload_project_id"])
			require.Equal(t, true, foundation["recovery_mode"])
			require.Equal(t, object{}, foundation["service_projects"])
			if files[6] == "foundation" {
				require.NoFileExists(t, filepath.Join(files[7], "active.tfvars.json"))
				return
			}
			active := result(t, fixture, "active.tfvars.json")
			staging := result(t, fixture, "staging.tfvars.json")
			require.Nil(t, staging["application_release"])
			require.Equal(t, "agora-production-test", active["recovery_source_project_id"])
			require.Equal(t, "12345678901234567890", field(active, "database_hosts", "json_keys", "data_disk_id"))
			require.Equal(t, "recovery-network", active["network_id"])
			require.Regexp(t, `^c-[a-f0-9]{16}$`, field(active, "application_release", "rollout", "candidate_tag"))
			if name == "LegacyHost" {
				require.Equal(t, "10.20.0.99", field(active, "recovery_source_database_ips", "json_keys"))
			} else {
				require.Equal(t, "10.20.0.3", field(active, "recovery_source_database_ips", "json_keys"))
			}
			for _, service := range []string{"authentication", "json_keys"} {
				app := section(active, "application_release", service)
				require.Equal(t, app["revision"], app["active_revision"])
				for _, image := range section(app, "images") {
					require.Contains(t, image, "/agora-recovery-test/agora-production/")
				}
				require.Contains(t, field(active, "recovery_database_images", service), "/agora-production-test/agora-production/")
			}
			preflight := result(t, fixture, "preflight.json")
			require.Equal(t, field(read(t, filepath.Join(fixture.first, "release.json")), "cloud", "secretVersions"), field(preflight, "cloud", "secretVersions"))
			expected := json.Number("4")
			if name == "CustomQuotas" {
				expected = "8"
			}
			require.Equal(t, expected, field(preflight, "cloud", "quotaExpectations", "compute_cpu"))
			data, err := os.ReadFile(filepath.Join(files[7], "images.json"))
			require.NoError(t, err)
			var images []object
			require.NoError(t, json.Unmarshal(data, &images))
			require.Len(t, images, 8)
			for _, image := range images {
				require.Contains(t, image["target"], "/agora-recovery-test/agora-production/")
				require.Contains(t, image["source"], "/agora-production-test/agora-production/")
				require.Contains(t, image["tag"], ":recovery-124")
			}
		})
	}
}
