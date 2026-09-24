package preflight_test

import "testing"

func TestServiceInputs(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name   string
		mutate func(object, object)
	}{
		{"MissingRole", func(m, _ object) { delete(images(m, "json-keys"), "database") }},
		{"MixedVersions", func(m, _ object) { images(m, "json-keys")["grpc"].(object)["tag"] = "v9.0.0" }},
		{"WrongSourcePath", func(m, _ object) { images(m, "json-keys")["grpc"].(object)["repository"] = "private-diagnostic" }},
		{"WrongDigest", func(m, _ object) { images(m, "json-keys")["grpc"].(object)["digest"] = "private-diagnostic" }},
		{"DisabledFamily", func(m, _ object) { m["components"].(object)["service-json-keys"].(object)["enabled"] = false }},
		{"WrongMajor", func(m, _ object) { m["postgresMajor"] = 17 }},
		{"MissingJob", func(_, c object) { delete(c["images"].(object), "migrations") }},
		{"InitializerJob", func(_, c object) { c["images"].(object)["init"] = "private-diagnostic" }},
		{"ForeignJobPin", func(_, c object) { c["images"].(object)["rotatekeys"] = "private-diagnostic" }},
		{"ForeignProject", func(_, c object) { c["project_id"] = "fixture-other" }},
		{"WrongAPIPin", func(_, c object) { c["rollout"] = object{"image": "private-diagnostic"} }},
		{"UnknownService", func(_, c object) { c["service"] = "private-diagnostic" }},
		{"InvalidRegion", func(_, c object) { c["region"] = "--private-diagnostic" }},
	} {
		t.Run("Error/"+testCase.name, func(t *testing.T) {
			t.Parallel()
			manifest := read(t, "../../tests/fixtures/manifests/valid.yaml")
			inputs := serviceInputs(manifest, "json-keys")
			testCase.mutate(manifest, inputs)
			checkCalls(t, []string{"service-images", write(t, manifest), write(t, inputs)}, nil, 65)
		})
	}
	for _, testCase := range []struct {
		name   string
		mutate func(object)
	}{
		{"Missing", func(c object) { delete(c, "secret_versions") }},
		{"Zero", func(c object) { c["secret_versions"].(object)["postgres-password"] = 0 }},
		{"Fraction", func(c object) { c["secret_versions"].(object)["postgres-password"] = 1.5 }},
		{"Alias", func(c object) { c["secret_versions"].(object)["postgres-password"] = "latest" }},
		{"NumericString", func(c object) { c["secret_versions"].(object)["postgres-password"] = "2" }},
		{"ExtraSMTP", func(c object) { c["secret_versions"].(object)["smtp-sender-password"] = 4 }},
		{"WrongSecret", func(c object) { c["secret_versions"] = object{"super-admin-password": 1} }},
		{"ProjectInjection", func(c object) { c["management_project_id"] = "--private-diagnostic" }},
		{"WrongFieldCase", func(c object) { c["MANAGEMENT_PROJECT_ID"] = "fixture-management"; delete(c, "management_project_id") }},
	} {
		t.Run("Secrets/"+testCase.name, func(t *testing.T) {
			t.Parallel()
			inputs := serviceInputs(read(t, "../../tests/fixtures/manifests/valid.yaml"), "authentication")
			testCase.mutate(inputs)
			checkCalls(t, []string{"service-secrets", write(t, inputs)}, nil, 65)
		})
	}
}
