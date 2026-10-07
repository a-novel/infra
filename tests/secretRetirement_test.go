package tests_test

import (
	"fmt"
	"maps"
	"testing"
)

func retiredSecretPlan(service string) object {
	secret := "production-" + service + "-postgres-backup-password"
	before := object{
		"project": "a-novel-management-prod", "secret_id": secret,
		"id":                  "projects/a-novel-management-prod/secrets/" + secret,
		"deletion_protection": true, "deletion_policy": "PREVENT", "version_destroy_ttl": "2592000s",
	}
	after := maps.Clone(before)
	after["deletion_protection"], after["deletion_policy"] = false, "DELETE"
	value := plan("google_secret_manager_secret", before, after)
	value["variables"] = object{"management_project_id": object{"value": "a-novel-management-prod"}}
	resource(value)["index"] = secret
	resource(value)["address"] = fmt.Sprintf("google_secret_manager_secret.retiring_backup[%q]", secret)
	resource(value)["previous_address"] = fmt.Sprintf("google_secret_manager_secret.application[%q]", secret)
	return value
}

func TestRetiredSecretProtection(t *testing.T) {
	t.Parallel()
	for _, service := range []string{"authentication", "json-keys"} {
		t.Run(service, func(t *testing.T) {
			t.Parallel()
			f := setup(t)
			f.summary(t, "bootstrap", retiredSecretPlan(service), 3)
			f.summary(t, "foundation", retiredSecretPlan(service), 65)
		})
	}
	for _, testCase := range []struct {
		name   string
		mutate func(object)
	}{
		{"OtherService", func(p object) { resource(p)["index"] = "production-other-postgres-backup-password" }},
		{"ActiveResource", func(p object) { resource(p)["address"] = resource(p)["previous_address"] }},
		{"NoMove", func(p object) { delete(resource(p), "previous_address") }},
		{"OtherProject", func(p object) { nested(p, "variables", "management_project_id")["value"] = "other-project" }},
		{"WrongID", func(p object) { nested(resource(p), "change", "before")["id"] = "other-secret" }},
		{"ChangedField", func(p object) { nested(resource(p), "change", "after")["annotations"] = object{"other": "value"} }},
		{"ChangedDelay", func(p object) { nested(resource(p), "change", "after")["version_destroy_ttl"] = "0s" }},
		{"UnprotectedBefore", func(p object) { nested(resource(p), "change", "before")["deletion_policy"] = "ABANDON" }},
		{"UnknownField", func(p object) { nested(resource(p), "change")["after_unknown"] = object{"id": true} }},
		{"UnknownResource", func(p object) { nested(resource(p), "change")["after_unknown"] = true }},
		{"Import", func(p object) { nested(resource(p), "change")["importing"] = object{"id": "other"} }},
		{"Replacement", func(p object) { nested(resource(p), "change")["actions"] = []string{"delete", "create"} }},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			p := retiredSecretPlan("json-keys")
			testCase.mutate(p)
			setup(t).summary(t, "bootstrap", p, 65)
		})
	}
}
