package release_test

import (
	"bytes"
	"os"
	"path/filepath"
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
			require.Equal(t, testCase.code, release.Run(testCase.args, &stdout, &stderr))
			require.NotContains(t, stderr.String(), "private-payload")
		})
	}
	for _, raw := range []string{"{\"private-payload\":", `{} {"private-payload":true}`, "private-payload: [", "schemaVersion: 1\n---\nprivate-payload: true"} {
		t.Run("Malformed/"+strings.ReplaceAll(raw, "/", "_"), func(t *testing.T) {
			t.Parallel()
			file := filepath.Join(t.TempDir(), "input")
			require.NoError(t, os.WriteFile(file, []byte(raw), 0o600))
			var out, diagnostics bytes.Buffer
			require.Equal(t, 65, release.Run([]string{"validate-images", file, file}, &out, &diagnostics))
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
			require.Equal(t, code, release.Run([]string{"validate-images", file, fixture.files[0]}, &stdout, &stderr), stderr.String())
		})
	}
}

func TestAuthenticationWithoutInitializer(t *testing.T) {
	t.Parallel()
	for _, name := range []string{"RetireInitializer", "LaterRelease", "PartialFamily", "MixedVersions"} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			fixture := setup(t)
			previous := read(t, fixture.files[0])
			fixture.change("authentication", true)
			if name == "LaterRelease" {
				delete(section(previous, "components", "service-authentication", "images"), "jobs/init")
			}
			nextImages := section(fixture.manifest, "components", "service-authentication", "images")
			delete(nextImages, "jobs/init")
			code := 0
			if name == "PartialFamily" {
				nextImages["rest"] = field(previous, "components", "service-authentication", "images", "rest")
				code = 65
			}
			if name == "MixedVersions" {
				section(nextImages, "rest")["tag"] = "v5.0.0"
				code = 65
			}
			for _, family := range section(fixture.manifest, "components") {
				for _, value := range family.(object)["images"].(object) {
					delete(value.(object), "digest")
				}
			}
			file := filepath.Join(t.TempDir(), "previous.json")
			write(t, file, previous)
			write(t, fixture.files[0], fixture.manifest)
			var stdout, stderr bytes.Buffer
			require.Equal(t, code, release.Run([]string{"validate-images", file, fixture.files[0]}, &stdout, &stderr), stderr.String())
		})
	}
}
