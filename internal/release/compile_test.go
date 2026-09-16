package release_test

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestCompiler(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, service string
		database      bool
	}{
		{"Success/Maintenance", "", false},
		{"Success/Authentication", "authentication", true},
		{"Success/JSONKeys", "json_keys", true},
		{"Success/AuthenticationSameDatabase", "authentication", false},
		{"Success/JSONKeysSameDatabase", "json_keys", false},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			fixture := setup(t)
			if testCase.service != "" {
				fixture.change(testCase.service, testCase.database)
			}
			require.NoError(t, fixture.compile(t, "deploy", "", ""))
			release := result(t, fixture, "release.json")
			require.Len(t, release["images"], 8)
			require.Len(t, field(release, "cloud", "secretVersions"), 7)
			require.Regexp(t, `^c-[a-f0-9]{16}$`, release["candidateTag"])
			for _, file := range []string{"candidate.tfvars.json", "active.tfvars.json", "rollback.tfvars.json"} {
				output := result(t, fixture, file)
				if testCase.service == "" {
					require.Equal(t, "maintenance", release["mode"])
					continue
				}
				other := "authentication"
				if testCase.service == other {
					other = "json_keys"
				}
				require.Equal(t, "service", release["mode"])
				require.Equal(t, []any{testCase.service}, release["services"])
				require.Equal(t, release["services"], field(output, "application_release", "rollout", "services"))
				require.Equal(t, field(fixture.receipt, "activeTfvars", "application_release", other), field(output, "application_release", other))
				require.Equal(t, field(fixture.receipt, "activeTfvars", "database_releases", other), field(output, "database_releases", other))
				require.Equal(t, field(fixture.receipt, "database", "hosts", other), field(release, "database", "hosts", other))
			}
			if !testCase.database {
				require.Equal(t, fixture.receipt["database"], release["database"])
			}
			for _, service := range []string{"authentication", "json_keys"} {
				candidate := result(t, fixture, "candidate.tfvars.json")
				require.Equal(t, field(fixture.receipt, "activeTfvars", "application_release", service, "active_revision"), field(candidate, "application_release", service, "active_revision"))
			}
		})
	}
	for _, testCase := range []struct {
		name          string
		mutate        func(*fixture)
		action, prior string
	}{
		{"PartialFamily", func(f *fixture) {
			section(f.manifest, "components", "service-json-keys", "images", "grpc")["tag"] = "v9.0.0"
		}, "deploy", ""},
		{"MutableTag", func(f *fixture) {
			section(f.manifest, "components", "service-json-keys", "images", "grpc")["digest"] = "sha256:" + strings.Repeat("3", 64)
		}, "deploy", ""},
		{"BothFamilies", func(f *fixture) { f.change("json_keys", true); f.change("authentication", true) }, "deploy", ""},
		{"PeerConfig", func(f *fixture) {
			f.change("json_keys", true)
			section(f.config, "authentication", "smtp")["sender_name"] = "private-value"
		}, "deploy", ""},
		{"PeerBackupVersion", func(f *fixture) {
			f.change("json_keys", true)
			section(f.config, "secret_versions")["authentication_postgres_backup_password"] = 99
		}, "deploy", ""},
		{"SharedConfig", func(f *fixture) { f.change("json_keys", true); f.config["backup_bucket_name"] = "private-value" }, "deploy", ""},
		{"MovedAddress", func(f *fixture) { section(f.config, "database_hosts", "authentication")["private_ip"] = "10.20.0.99" }, "deploy", ""},
		{"MovedDisk", func(f *fixture) { section(f.config, "database_hosts", "authentication")["data_disk_id"] = "9999" }, "rollback", ""},
		{"UnprovenLegacy", func(f *fixture) { delete(f.receipt, "imageManifest") }, "deploy", ""},
		{"WrongLegacyManifest", func(f *fixture) { delete(f.receipt, "imageManifest"); f.change("json_keys", true) }, "deploy", "self"},
		{"LegacyRollback", func(f *fixture) { delete(section(f.receipt, "database"), "hosts") }, "rollback", ""},
		{"LegacyRebuildAndImages", func(f *fixture) { delete(section(f.receipt, "database"), "hosts"); f.change("json_keys", true) }, "deploy", ""},
		{"MissingRollback", func(f *fixture) { f.receipt = nil; f.files[2] = "-" }, "rollback", ""},
		{"WorkflowIdentity", func(f *fixture) { f.identity.Commit = "private-value" }, "deploy", ""},
	} {
		t.Run("Error/"+testCase.name, func(t *testing.T) {
			t.Parallel()
			fixture := setup(t)
			testCase.mutate(fixture)
			prior := testCase.prior
			if prior == "self" {
				prior = fixture.files[0]
			}
			err := fixture.compile(t, testCase.action, prior, "")
			require.Error(t, err)
			require.NotContains(t, err.Error(), "private-value")
			require.NoDirExists(t, fixture.files[3])
		})
	}
	for _, name := range []string{"FirstLaunch", "CompensatedLaunch", "LegacyManifest", "LegacyRebuild", "RollbackPins"} {
		t.Run("Success/"+name, func(t *testing.T) {
			t.Parallel()
			fixture := setup(t)
			action, prior, current := "deploy", "", ""
			switch name {
			case "FirstLaunch":
				fixture.files[2] = "-"
				fixture.receipt = nil
			case "CompensatedLaunch":
				fixture.receipt["database"] = nil
				section(fixture.receipt, "activeTfvars")["application_release"] = nil
				action = "rollback"
			case "LegacyManifest":
				delete(fixture.receipt, "imageManifest")
				prior = "../../tests/fixtures/manifests/valid.yaml"
			case "LegacyRebuild":
				delete(section(fixture.receipt, "database"), "hosts")
				delete(section(fixture.receipt, "activeTfvars"), "database_hosts")
				section(fixture.receipt, "activeTfvars")["database_private_ip"] = "10.20.0.99"
			case "RollbackPins":
				action = "rollback"
				delete(section(fixture.config, "authentication"), "web_client_url")
				delete(section(fixture.receipt, "activeTfvars", "application_release", "authentication"), "web_client_url")
				for key := range section(fixture.config, "secret_versions") {
					section(fixture.config, "secret_versions")[key] = 99
				}
				live := read(t, fixture.files[2])
				section(live, "database")["jsonKeysPasswordVersion"] = 99
				current = filepath.Join(t.TempDir(), "current.json")
				write(t, current, live)
			}
			require.NoError(t, fixture.compile(t, action, prior, current))
			release, rollback := result(t, fixture, "release.json"), result(t, fixture, "rollback.tfvars.json")
			switch name {
			case "FirstLaunch":
				require.Equal(t, "first-launch", release["mode"])
				require.Nil(t, rollback["application_release"])
				for _, service := range []string{"authentication", "json_keys"} {
					require.NotContains(t, section(result(t, fixture, "candidate.tfvars.json"), "application_release", service), "active_revision")
				}
			case "CompensatedLaunch":
				require.Empty(t, field(release, "cloud", "secretVersions"))
				require.Nil(t, rollback["application_release"])
			case "LegacyRebuild":
				require.Equal(t, "database-rebuild", release["mode"])
				require.Nil(t, release["currentDatabase"])
				require.Nil(t, release["previousDatabase"])
				require.Equal(t, result(t, fixture, "candidate.tfvars.json"), rollback)
			case "RollbackPins":
				require.Equal(t, fixture.receipt["database"], release["previousDatabase"])
				require.Equal(t, json.Number("99"), field(release, "currentDatabase", "jsonKeysPasswordVersion"))
				require.NotContains(t, section(rollback, "application_release", "authentication"), "web_client_url")
				require.Equal(t, field(read(t, filepath.Join(fixture.first, "release.json")), "cloud", "secretVersions"), field(release, "cloud", "secretVersions"))
			}
			info, err := os.Stat(fixture.files[3])
			require.NoError(t, err)
			require.Equal(t, os.FileMode(0o700), info.Mode().Perm())
			for _, file := range []string{"release.json", "active.tfvars.json", "candidate.tfvars.json", "rollback.tfvars.json"} {
				info, err = os.Stat(filepath.Join(fixture.files[3], file))
				require.NoError(t, err)
				require.Equal(t, os.FileMode(0o600), info.Mode().Perm())
			}
		})
	}
}
