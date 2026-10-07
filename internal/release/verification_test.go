package release_test

import (
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/a-novel/infra/internal/release"
)

func TestVerificationImages(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name    string
		service string
		mutate  func(object)
	}{
		{"EmptyService", "", nil},
		{"UnknownService", "peer", nil},
		{"Schema", "json-keys", func(v object) { v["schemaVersion"] = 2 }},
		{"Major", "json-keys", func(v object) { v["postgresMajor"] = 17 }},
		{"MissingSlot", "json-keys", func(v object) { delete(section(v, "components", "service-json-keys", "images"), "grpc") }},
		{"ForeignSource", "json-keys", func(v object) {
			section(v, "components", "service-json-keys", "images", "grpc")["repository"] = "private-diagnostic"
		}},
		{"MutableTag", "json-keys", func(v object) { section(v, "components", "service-json-keys", "images", "grpc")["tag"] = "latest" }},
		{"MalformedDigest", "json-keys", func(v object) {
			section(v, "components", "service-json-keys", "images", "grpc")["digest"] = "private-diagnostic"
		}},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			manifest := read(t, "../../tests/fixtures/manifests/valid.yaml")
			if testCase.mutate != nil {
				testCase.mutate(manifest)
			}
			file := filepath.Join(t.TempDir(), "manifest.json")
			write(t, file, manifest)
			_, err := release.VerificationImages(file, testCase.service)
			require.Error(t, err)
			require.NotContains(t, err.Error(), "private-diagnostic")
		})
	}
}
