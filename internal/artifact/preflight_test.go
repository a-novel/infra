package artifact_test

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestRunImages(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, service string
		failure       int
	}{
		{"Success/Legacy", "", -1},
		{"Success/JSONKeys", "json-keys", -1},
		{"Success/Authentication", "authentication", -1},
		{"Error/Provenance", "json-keys", 0},
		{"Error/Registry", "authentication", 1},
		{"Error/LaterImage", "json-keys", 7},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			manifest := read(t, "../../tests/fixtures/manifests/valid.yaml")
			calls := imageCalls(manifest, testCase.service)
			var args []string
			if testCase.service == "" {
				compiled := compiledRelease(t, manifest)
				compiled["schemaVersion"], compiled["postgresMajor"] = json.Number("1e0"), json.Number("18.0")
				args = []string{"images", write(t, compiled)}
			} else {
				for name, definition := range manifest["components"].(object) {
					if name != "service-"+testCase.service {
						definition.(object)["enabled"] = false
						definition.(object)["images"] = object{}
					}
				}
				inputs := serviceInputs(manifest, testCase.service)
				if testCase.service == "json-keys" {
					inputs["rollout"] = object{"image": "europe-west1-docker.pkg.dev/fixture-service/agora-production/service-json-keys/grpc@" + images(manifest, "json-keys")["grpc"].(object)["digest"].(string)}
				}
				args = []string{"service-images", write(t, manifest), write(t, inputs)}
			}
			code := 0
			if testCase.failure >= 0 {
				code = 70
				calls = calls[:testCase.failure+1]
				calls[testCase.failure].fail = true
			}
			checkCalls(t, args, calls, code)
		})
	}
}

func TestResolveImages(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name    string
		failure int
	}{
		{"Snapshot", -1},
		{"MissingTag", 0},
		{"Provenance", 1},
		{"TagMovedAfterResolution", 2},
		{"LastImage", 23},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			expected := read(t, "../../tests/fixtures/manifests/valid.yaml")
			manifest := read(t, "../../tests/fixtures/manifests/valid.yaml")
			var calls []call
			checks := imageCalls(expected, "")
			for index := 0; index < len(checks); index += 2 {
				registry := checks[index+1]
				calls = append(calls, call{"resolve", registry.args[:1], registry.args[1], false}, checks[index], registry)
			}
			for _, component := range manifest["components"].(object) {
				for _, image := range component.(object)["images"].(object) {
					delete(image.(object), "digest")
				}
			}
			output := filepath.Join(t.TempDir(), "resolved.json")
			code := 0
			if testCase.failure >= 0 {
				code = 70
				calls = calls[:testCase.failure+1]
				calls[testCase.failure].fail = true
			}
			checkCalls(t, []string{"resolve-images", write(t, manifest), output}, calls, code)
			if code != 0 {
				require.NoFileExists(t, output)
				return
			}
			require.Equal(t, expected, read(t, output))
			info, err := os.Stat(output)
			require.NoError(t, err)
			require.Equal(t, os.FileMode(0o600), info.Mode().Perm())
		})
	}
}

func TestServiceVersions(t *testing.T) {
	t.Parallel()
	for _, service := range []string{"json-keys", "authentication"} {
		t.Run(service, func(t *testing.T) {
			t.Parallel()
			manifest := read(t, "../../tests/fixtures/manifests/valid.yaml")
			inputs := serviceInputs(manifest, service)
			checks := imageCalls(manifest, service)
			var calls []call
			for index := 1; index < len(checks); index += 2 {
				registry := checks[index]
				calls = append(calls, call{"resolve", registry.args[:1], registry.args[1], false})
				delete(images(manifest, service)[registry.args[2]].(object), "digest")
			}
			calls = append(calls, checks...)
			for name, component := range manifest["components"].(object) {
				if !strings.HasSuffix(name, service) {
					component.(object)["enabled"], component.(object)["images"] = false, object{}
				}
			}
			checkCalls(t, []string{"service-images", write(t, manifest), write(t, inputs)}, calls, 0)
		})
	}
}

func TestRunSecrets(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, service, state string
		fail                 bool
	}{
		{"Success/JSONKeys", "json-keys", "ENABLED\n", false},
		{"Success/Authentication", "authentication", "ENABLED\n", false},
		{"Error/Disabled", "json-keys", "DISABLED", false},
		{"Error/Destroyed", "authentication", "DESTROYED", false},
		{"Error/Missing", "json-keys", "", true},
		{"Error/Denied", "authentication", "", true},
		{"Error/Unexpected", "json-keys", "private-diagnostic", false},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			inputs := serviceInputs(read(t, "../../tests/fixtures/manifests/valid.yaml"), testCase.service)
			calls := []call{{"gcloud", []string{"secrets", "versions", "describe", "2", "--secret=production-" + testCase.service + "-postgres-password", "--project=fixture-management", "--format=value(state)", "--quiet"}, testCase.state, testCase.fail}}
			code := 70
			if testCase.state == "ENABLED\n" {
				code = 0
				if testCase.service == "json-keys" {
					calls = append(calls, call{"gcloud", []string{"secrets", "versions", "describe", "7", "--secret=production-json-keys-app-master-key", "--project=fixture-management", "--format=value(state)", "--quiet"}, "ENABLED", false})
				}
			}
			checkCalls(t, []string{"service-secrets", write(t, inputs)}, calls, code)
		})
	}
}
