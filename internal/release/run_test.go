package release_test

import (
	"bytes"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/a-novel/infra/internal/release"
)

func TestRun(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name string
		args []string
		code int
	}{
		{"Usage", nil, 64},
		{"Unknown", []string{"unsafe"}, 64},
		{"ShortRelease", []string{"compile-release"}, 64},
		{"ShortRecovery", []string{"compile-recovery"}, 64},
		{"ShortImages", []string{"validate-images"}, 64},
		{"ShortReceipt", []string{"receipt"}, 64},
		{"MissingFile", []string{"receipt", "validate", "private-payload-file"}, 65},
		{"ProductionManifest", []string{"validate-images", "../../deploy/production/images.yaml", "../../deploy/production/images.yaml"}, 0},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			var stdout, stderr bytes.Buffer
			require.Equal(t, testCase.code, release.Run(testCase.args, func(string) string { return "" }, &stdout, &stderr))
			require.NotContains(t, stderr.String(), "private-payload")
		})
	}
	invalid := []struct {
		name   string
		mutate func(*fixture)
	}{
		{"ExtraProperty", func(f *fixture) { f.config["private-payload"] = "private-payload" }},
		{"MissingPin", func(f *fixture) { delete(section(f.config, "secret_versions"), "json_keys_app_master_key") }},
		{"UnpinnedSecret", func(f *fixture) { section(f.config, "secret_versions")["json_keys_app_master_key"] = "private-payload" }},
		{"FractionalPin", func(f *fixture) { section(f.config, "secret_versions")["json_keys_app_master_key"] = 1.5 }},
		{"CoercedTag", func(f *fixture) {
			section(f.config, "cloud_run_invocation_tags", "values")["internal"] = []string{"tagValues/123"}
		}},
		{"BadIP", func(f *fixture) { section(f.config, "database_hosts", "authentication")["private_ip"] = "10.0.0.256" }},
		{"SharedIP", func(f *fixture) {
			section(f.config, "database_hosts", "authentication")["private_ip"] = field(f.config, "database_hosts", "json_keys", "private_ip")
		}},
		{"SharedDisk", func(f *fixture) {
			section(f.config, "database_hosts", "authentication")["data_disk_id"] = field(f.config, "database_hosts", "json_keys", "data_disk_id")
		}},
		{"MissingHost", func(f *fixture) { delete(section(f.config, "database_hosts"), "authentication") }},
		{"PublicIP", func(f *fixture) { section(f.config, "database_hosts", "authentication")["private_ip"] = "8.8.8.8" }},
		{"Zone", func(f *fixture) { f.config["database_zone"] = "europe-west2-a" }},
		{"BranchTag", func(f *fixture) {
			section(f.manifest, "components", "service-json-keys", "images", "grpc")["tag"] = "feat-update"
		}},
		{"UnresolvedNewVersion", func(f *fixture) {
			f.change("json_keys", true)
			delete(section(f.manifest, "components", "service-json-keys", "images", "grpc"), "digest")
		}},
		{"MissingImage", func(f *fixture) { delete(section(f.manifest, "components", "service-json-keys", "images"), "grpc") }},
		{"WrongSlot", func(f *fixture) {
			section(f.manifest, "components", "service-json-keys", "images", "grpc")["repository"] = "ghcr.io/a-novel/service-json-keys/database"
		}},
		{"FutureImage", func(f *fixture) {
			section(f.manifest, "components", "service-json-keys", "images")["future"] = object{}
		}},
		{"PostgresMajor", func(f *fixture) { f.manifest["postgresMajor"] = 17 }},
		{"DisabledImages", func(f *fixture) { section(f.manifest, "components", "service-json-keys")["enabled"] = false }},
	}
	for index, origin := range []any{nil, "", "/account", "http://www.example.com", "https://private-payload@www.example.com", "https://www.example.com/path", "https://www.example.com/", "https://www.example.com?private-payload", "https://www.example.com#private-payload", " https://www.example.com", "https://www.example.com:99999", "https://www.example.com\\path", "https://www.example.com:443", "https://1.2.3.09", "https://999.999.999.999"} {
		invalid = append(invalid, struct {
			name   string
			mutate func(*fixture)
		}{name: "Origin/" + strconv.Itoa(index), mutate: func(f *fixture) { section(f.config, "authentication")["web_client_url"] = origin }})
	}
	for _, testCase := range invalid {
		t.Run("Error/"+testCase.name, func(t *testing.T) {
			t.Parallel()
			fixture := setup(t)
			testCase.mutate(fixture)
			err := fixture.compile(t, "deploy", "", "")
			require.Error(t, err)
			require.NotContains(t, err.Error(), "private-payload")
			require.NoDirExists(t, fixture.files[3])
		})
	}
	for _, raw := range []string{"{\"private-payload\":", `{} {"private-payload":true}`, "private-payload: [", "schemaVersion: 1\n---\nprivate-payload: true"} {
		t.Run("Malformed/"+strings.ReplaceAll(raw, "/", "_"), func(t *testing.T) {
			t.Parallel()
			file := filepath.Join(t.TempDir(), "input")
			require.NoError(t, os.WriteFile(file, []byte(raw), 0o600))
			var out, diagnostics bytes.Buffer
			require.Equal(t, 65, release.Run([]string{"validate-images", file, file}, func(string) string { return "" }, &out, &diagnostics))
			require.NotContains(t, diagnostics.String(), "private-payload")
		})
	}
}

func TestRunImageTransition(t *testing.T) {
	t.Parallel()
	for _, name := range []string{"FirstLaunch", "Service", "PartialFamily", "BothServices", "MixedVersions", "MaintainedDigest"} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			fixture := setup(t)
			previous := read(t, fixture.files[0])
			fixture.change("json_keys", true)
			code := 65
			switch name {
			case "FirstLaunch":
				for _, service := range []string{"service-json-keys", "service-authentication"} {
					definition := section(previous, "components", service)
					definition["enabled"], definition["images"] = false, object{}
				}
				code = 0
			case "Service":
				code = 0
			case "PartialFamily":
				section(fixture.manifest, "components", "service-json-keys", "images")["grpc"] = field(previous, "components", "service-json-keys", "images", "grpc")
			case "BothServices":
				fixture.change("authentication", true)
			case "MixedVersions":
				section(fixture.manifest, "components", "service-json-keys", "images", "grpc")["tag"] = "v5.0.0"
			}
			file := filepath.Join(t.TempDir(), "previous.json")
			write(t, file, previous)
			if name != "MaintainedDigest" {
				for _, value := range section(fixture.manifest, "components") {
					for _, image := range value.(object)["images"].(object) {
						delete(image.(object), "digest")
					}
				}
			}
			write(t, fixture.files[0], fixture.manifest)
			var stdout, stderr bytes.Buffer
			require.Equal(t, code, release.Run([]string{"validate-images", file, fixture.files[0]}, func(string) string { return "" }, &stdout, &stderr), stderr.String())
		})
	}
}
