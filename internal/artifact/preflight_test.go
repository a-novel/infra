package artifact_test

import (
	"encoding/json"
	"testing"
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
