package tests_test

import (
	"maps"
	"strings"
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

func TestRetiredServiceIdentityProtection(t *testing.T) {
	t.Parallel()
	for _, target := range []struct{ scope, project, account, provider string }{
		{"authentication/private", "a-novel-production-prod", "infra-authentication-private", "r-0f9b006d46081025fb6903ef7f0c"},
		{"authentication/public-api", "a-novel-public-api-prod", "infra-authentication-api", "r-c4ce9a8eb5aa6471505b4ef23ae7"},
		{"json-keys/private", "a-novel-production-prod", "infra-json-keys-private", "r-fa8fb0969708fa1eae6efbaa7182"},
	} {
		for _, identity := range []struct{ kind, project, id string }{
			{"google_service_account", target.project, "projects/" + target.project + "/serviceAccounts/" + target.account + "@" + target.project + ".iam.gserviceaccount.com"},
			{"google_iam_workload_identity_pool_provider", "a-novel-management-prod", "projects/a-novel-management-prod/locations/global/workloadIdentityPools/github-actions/providers/" + target.provider},
		} {
			t.Run(target.scope+"/"+identity.kind, func(t *testing.T) {
				t.Parallel()
				for _, testCase := range []struct {
					name   string
					mutate func(object)
					code   int
				}{
					{"Success", func(object) {}, 3},
					{"Error/ActiveAddress", func(p object) { resource(p)["address"] = resource(p)["previous_address"] }, 65},
					{"Error/OtherScope", func(p object) {
						resource(p)["address"] = strings.ReplaceAll(resource(p)["address"].(string), target.scope, "other/private")
						resource(p)["previous_address"] = strings.ReplaceAll(resource(p)["previous_address"].(string), target.scope, "other/private")
					}, 65},
					{"Error/OtherIdentity", func(p object) {
						nested(resource(p), "change", "before")["id"] = "other"
						nested(resource(p), "change", "after")["id"] = "other"
					}, 65},
					{"Error/Unknown", func(p object) { nested(resource(p), "change")["after_unknown"] = true }, 65},
					{"Error/TrustChange", func(p object) { nested(resource(p), "change", "after")["attribute_condition"] = "true" }, 65},
					{"Error/Import", func(p object) { nested(resource(p), "change")["importing"] = object{"id": "other"} }, 65},
					{"Error/StillEnabled", func(p object) { nested(resource(p), "change", "after")["disabled"] = false }, 65},
				} {
					t.Run(testCase.name, func(t *testing.T) {
						t.Parallel()
						p := retiredProviderPlan()
						change := nested(resource(p), "change")
						for _, phase := range []string{"before", "after"} {
							value := nested(change, phase)
							value["project"], value["id"] = identity.project, identity.id
						}
						resource(p)["type"] = identity.kind
						resource(p)["address"] = `module.service_release["` + target.scope + `"].` + identity.kind + ".retiring_release"
						resource(p)["previous_address"] = `module.service_release["` + target.scope + `"].` + identity.kind + ".release"
						testCase.mutate(p)
						f := setup(t)
						f.summary(t, "foundation", p, testCase.code)
						f.summary(t, "bootstrap", p, 65)
					})
				}
			})
		}
	}
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
