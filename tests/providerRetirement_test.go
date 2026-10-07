package tests_test

import (
	"maps"
	"testing"
)

func retiredProviderPlan() object {
	before := object{
		"project":                   "a-novel-management-prod",
		"id":                        "projects/a-novel-management-prod/locations/global/workloadIdentityPools/github-actions/providers/github-release",
		"workload_identity_pool_id": "github-actions", "workload_identity_pool_provider_id": "github-release",
		"deletion_policy": "PREVENT", "disabled": false,
	}
	after := maps.Clone(before)
	after["deletion_policy"], after["disabled"] = "DELETE", true
	value := plan("google_iam_workload_identity_pool_provider", before, after)
	value["variables"] = object{"management_project_id": object{"value": "a-novel-management-prod"}}
	resource(value)["address"] = "google_iam_workload_identity_pool_provider.retiring_release"
	resource(value)["previous_address"] = `google_iam_workload_identity_pool_provider.github["release"]`
	return value
}

func TestRetiredProviderProtection(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name   string
		mutate func(object)
		code   int
	}{
		{"Success", func(object) {}, 3},
		{"ActiveResource", func(p object) { resource(p)["address"] = resource(p)["previous_address"] }, 65},
		{"NoMove", func(p object) { delete(resource(p), "previous_address") }, 65},
		{"OtherProject", func(p object) { nested(p, "variables", "management_project_id")["value"] = "other-project" }, 65},
		{"WrongID", func(p object) { nested(resource(p), "change", "before")["id"] = "other-provider" }, 65},
		{"TrustChange", func(p object) { nested(resource(p), "change", "after")["attribute_condition"] = "true" }, 65},
		{"StillEnabled", func(p object) { nested(resource(p), "change", "after")["disabled"] = false }, 65},
		{"UnknownField", func(p object) { nested(resource(p), "change")["after_unknown"] = object{"id": true} }, 65},
		{"UnknownResource", func(p object) { nested(resource(p), "change")["after_unknown"] = true }, 65},
		{"Import", func(p object) { nested(resource(p), "change")["importing"] = object{"id": "other"} }, 65},
		{"Replacement", func(p object) { nested(resource(p), "change")["actions"] = []string{"delete", "create"} }, 65},
		{"Deposed", func(p object) { resource(p)["deposed"] = "old" }, 65},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			p := retiredProviderPlan()
			testCase.mutate(p)
			f := setup(t)
			f.summary(t, "bootstrap", p, testCase.code)
			f.summary(t, "foundation", p, 65)
		})
	}
}
