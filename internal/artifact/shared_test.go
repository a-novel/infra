package artifact_test

import (
	"strings"
	"testing"
)

func TestSharedServiceImages(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, service, zone string
		mutate              func(object)
		code                int
	}{
		{"JSONKeysPrivate", "json-keys", "private", nil, 0},
		{"JSONKeysPrivateAPI", "json-keys", "private", nil, 0},
		{"AuthenticationPrivate", "authentication", "private", nil, 0},
		{"AuthenticationAPI", "authentication", "public-api", nil, 0},
		{"NativePrivate", "json-keys", "private", nil, 0},
		{"NativePublic", "authentication", "public-api", nil, 0},
		{"NativeWrongFamily", "authentication", "public-api", func(c object) { c["migration_image"] = "wrong-digest" }, 65},
		{"AuthenticationWithoutInitializerPrivate", "authentication", "private", nil, 0},
		{"AuthenticationWithoutInitializerAPI", "authentication", "public-api", nil, 0},
		{"PlatformZone", "authentication", "public", nil, 65},
		{"MissingSMTP", "authentication", "public-api", func(c object) { delete(c["secret_versions"].(object), "smtp-sender-password") }, 65},
		{"MasterKeyInAPI", "authentication", "public-api", func(c object) { c["secret_versions"].(object)["app-master-key"] = 7 }, 65},
		{"JobInAPI", "authentication", "public-api", func(c object) { c["images"].(object)["migrations"] = "private-diagnostic" }, 65},
		{"PrivateAuthAPI", "authentication", "private", func(c object) { c["api"] = object{"image": "private-diagnostic"} }, 65},
		{"PeerRegistry", "authentication", "public-api", func(c object) { c["api"].(object)["image"] = "private-diagnostic" }, 65},
		{"MissingAPIFamily", "json-keys", "public-api", nil, 65},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			manifest := read(t, "../../tests/fixtures/manifests/valid.yaml")
			if strings.Contains(testCase.name, "WithoutInitializer") {
				delete(images(manifest, "authentication"), "jobs/init")
			}
			inputs := serviceInputs(manifest, testCase.service)
			scope := testCase.zone
			if scope == "public-api" {
				scope = "api"
			}
			repository := "agora-" + testCase.service + "-" + scope + "-production"
			inputs["zone"] = testCase.zone
			for role, image := range inputs["images"].(object) {
				inputs["images"].(object)[role] = strings.ReplaceAll(image.(string), "agora-production", repository)
			}
			if testCase.name == "JSONKeysPrivateAPI" {
				digest := images(manifest, "json-keys")["grpc"].(object)["digest"].(string)
				inputs["api"] = object{"image": "europe-west1-docker.pkg.dev/fixture-service/" + repository + "/service-json-keys/grpc@" + digest}
			}
			if testCase.zone == "public-api" {
				inputs["images"] = object{}
				inputs["secret_versions"] = object{"postgres-password": 2}
				// JSON Keys REST is not yet in the committed producer family and must fail closed.
				digest := images(manifest, testCase.service)["grpc"]
				if testCase.service == "authentication" {
					digest = images(manifest, testCase.service)["rest"]
					inputs["authentication"] = object{}
					inputs["secret_versions"].(object)["smtp-sender-password"] = 4
				}
				inputs["api"] = object{"image": "europe-west1-docker.pkg.dev/fixture-service/" + repository + "/service-" + testCase.service + "/rest@" + digest.(object)["digest"].(string)}
			}
			if strings.HasPrefix(testCase.name, "Native") {
				inputs["private_project_id"] = "fixture-service"
				digest := images(manifest, testCase.service)["jobs/migrations"].(object)["digest"].(string)
				inputs["migration_image"] = "europe-west1-docker.pkg.dev/fixture-service/agora-" + testCase.service + "-private-production/service-" + testCase.service + "/jobs/migrations@" + digest
			}
			if testCase.mutate != nil {
				testCase.mutate(inputs)
			}
			var calls []call
			if testCase.code == 0 {
				calls = imageCalls(manifest, testCase.service)
			}
			checkCalls(t, []string{"service-images", write(t, manifest), write(t, inputs)}, calls, testCase.code)
		})
	}
}
