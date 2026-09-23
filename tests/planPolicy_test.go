package tests_test

import (
	_ "embed"
	"fmt"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

//go:embed testdata/protections.yaml
var protections []byte

func fieldValue(path string, value any) object {
	keys := strings.Split(path, ".")
	for index := len(keys) - 1; index >= 0; index-- {
		if keys[index] == "0" {
			value = []any{value}
		} else {
			value = object{keys[index]: value}
		}
	}
	return value.(object)
}

func plan(resourceType string, before, after any) object {
	return object{
		"format_version": "1.2", "terraform_version": "1.12.6", "errored": false,
		"resource_changes": []any{object{
			"mode": "managed", "type": resourceType, "address": privateValue,
			"change": object{"actions": []string{"update"}, "before": before, "after": after},
		}},
	}
}

func resource(value object) object { return value["resource_changes"].([]any)[0].(object) }

func (f *sandbox) summary(t *testing.T, root string, value object, expected int) string {
	t.Helper()
	file := filepath.Join(f.dir, "plan.json")
	writeJSON(t, file, value)
	code, out := f.script(t, "plan-summary", root, file)
	expectCode(t, expected, code, out)
	return out
}

func TestPlanSummary(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		fixture string
		code    int
		rows    []string
	}{
		{"safe", 0, []string{"create\tgoogle_cloud_run_v2_job\t1\tcurrent", "import\tgoogle_project\t1\tcurrent", "update\tgoogle_cloud_run_v2_service\t1\tcurrent"}},
		{"no-changes", 0, []string{"action\tresource_type\tcount\tgeneration"}},
		{"protected", 3, []string{"delete\tgoogle_project\t1\tdeposed", "forget\tgoogle_secret_manager_secret\t1\tcurrent", "replace\tgoogle_compute_disk\t1\tcurrent"}},
		{"unsupported", 65, []string{"unsupported action combination"}},
	} {
		t.Run(testCase.fixture, func(t *testing.T) {
			t.Parallel()
			f := setup(t)
			code, output := f.script(t, "plan-summary", "foundation", filepath.Join(f.root, "tests/fixtures/plans", testCase.fixture+".json"))
			expectCode(t, testCase.code, code, output)
			for _, row := range testCase.rows {
				require.Contains(t, output, row)
			}
			require.NotContains(t, output, "fixture-")
			require.NotContains(t, output, "no-op\t")
			if testCase.fixture == "no-changes" {
				require.Equal(t, testCase.rows[0]+"\n", output)
			}
		})
	}
}

func TestPlanProtections(t *testing.T) {
	t.Parallel()
	for _, rule := range fixtureYAML[[]struct {
		Type   string
		Fields map[string][]any
	}](t, protections) {
		for path, pair := range rule.Fields {
			t.Run(rule.Type+"/"+path, func(t *testing.T) {
				t.Parallel()
				f := setup(t)
				f.summary(t, "foundation", plan(rule.Type, fieldValue(path, pair[0]), fieldValue(path, pair[0])), 0)
				f.summary(t, "foundation", plan(rule.Type, fieldValue(path, pair[0]), fieldValue(path, pair[1])), 65)
			})
		}
	}
}

func TestPlanRetention(t *testing.T) {
	t.Parallel()
	for _, path := range []string{"retention_policy.0.retention_period", "soft_delete_policy.0.retention_duration_seconds"} {
		for index, testCase := range []struct {
			before, after any
			code          int
		}{
			{604800, 604800, 0},
			{"604800", 604800, 0},
			{604800, "604800", 0},
			{"604800", "1209600", 0},
			{"604800", "86400", 65},
			{604800, "86400", 65},
			{"604800", 86400, 65},
			{0, "0", 0},
			{"0", 0, 0},
			{"604800", nil, 65},
		} {
			t.Run(fmt.Sprintf("%s/Encoding/%d", path, index), func(t *testing.T) {
				t.Parallel()
				setup(t).summary(t, "bootstrap", plan("google_storage_bucket", fieldValue(path, testCase.before), fieldValue(path, testCase.after)), testCase.code)
			})
		}
		for index, value := range []any{true, false, []any{}, object{}, "", "604800s", " 604800", "604800\n", "+604800", "6.048e5", "604800.0", "-1", -1, 0.5, "9007199254740992", 9007199254740992, privateValue} {
			t.Run(fmt.Sprintf("%s/Invalid/%d", path, index), func(t *testing.T) {
				t.Parallel()
				f := setup(t)
				for _, side := range []string{"before", "after"} {
					valuePlan := plan("google_storage_bucket", fieldValue(path, "604800"), fieldValue(path, "604800"))
					nested(resource(valuePlan), "change")[side] = fieldValue(path, value)
					f.summary(t, "bootstrap", valuePlan, 65)
				}
			})
		}
	}
}

func TestPlanChecks(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name, key string
		value     any
	}{
		{"Errored", "errored", true},
		{"UnsupportedFormat", "format_version", "2.0"},
		{"ChecksShape", "checks", false},
		{"InstancesShape", "checks", []any{object{"status": "pass", "instances": false}}},
		{"InstanceFailure", "checks", []any{object{"status": "pass", "instances": []any{object{"status": "fail"}}}}},
	}
	for _, status := range []any{"fail", "error", "unknown", "unsupported", nil} {
		cases = append(cases, struct {
			name, key string
			value     any
		}{fmt.Sprint(status), "checks", []any{object{"status": status, "instances": []any{object{"status": status, "problems": []any{object{"message": privateValue}}}}}}})
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			value := plan("future_resource", object{}, object{})
			value[testCase.key] = testCase.value
			setup(t).summary(t, "foundation", value, 65)
		})
	}
	for _, testCase := range []struct{ address, outer, inner, diagnostic string }{
		{"google_cloud_quotas_quota_preference.cost_cap", "unknown", "unknown", "REGIONAL_QUOTA_SELECTION (unknown, 1 checks)"},
		{privateValue, "pass", "fail", "OTHER_CHECK (fail, 1 checks)"},
		{privateValue, privateValue, "pass", "OTHER_CHECK (invalid, 1 checks)"},
	} {
		t.Run(testCase.diagnostic, func(t *testing.T) {
			t.Parallel()
			value := plan("future_resource", object{}, object{})
			value["checks"] = []any{object{
				"address": object{"to_display": testCase.address, "kind": privateValue}, "status": testCase.outer,
				"instances": []any{object{"status": testCase.inner, "address": object{"instance_key": privateValue, "to_display": privateValue}, "problems": []any{object{"message": privateValue}}}},
			}}
			require.Contains(t, setup(t).summary(t, "foundation", value, 65), testCase.diagnostic)
		})
	}
}

func TestPlanChanges(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name   string
		mutate func(object)
		code   int
	}{
		{"MissingAfter", func(p object) { nested(resource(p), "change")["after"] = nil }, 65},
		{"AddedCleanup", func(p object) {
			nested(resource(p), "change", "after")["lifecycle_rule"] = []any{object{"action": []any{object{"type": "Delete"}}, "condition": []any{object{"age": 1}}}}
		}, 65},
		{"StrongerRetention", func(p object) {
			change := nested(resource(p), "change")
			change["after"] = fieldValue("retention_policy.0.retention_period", "1209600")
			nested(change, "before")["labels"] = object{"version": "old"}
			nested(change, "after")["labels"] = object{"version": "new"}
			change["after_unknown"] = object{"id": true}
			p["checks"] = []any{object{"status": "pass", "instances": []any{object{"status": "pass"}}}}
		}, 0},
		{"UnknownResource", func(p object) { nested(resource(p), "change")["after_unknown"] = true }, 65},
		{"UnknownBlock", func(p object) { nested(resource(p), "change")["after_unknown"] = object{"retention_policy": true} }, 65},
		{"UnknownField", func(p object) {
			nested(resource(p), "change")["after_unknown"] = fieldValue("retention_policy.0.retention_period", true)
		}, 65},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			value := plan("google_storage_bucket", fieldValue("retention_policy.0.retention_period", "604800"), fieldValue("retention_policy.0.retention_period", "604800"))
			testCase.mutate(value)
			setup(t).summary(t, "bootstrap", value, testCase.code)
		})
	}
	for _, actions := range [][]string{{"delete"}, {"delete", "create"}, {"create", "delete"}, {"forget"}} {
		t.Run(strings.Join(actions, "/"), func(t *testing.T) {
			t.Parallel()
			value := plan("future_resource", object{}, object{})
			nested(resource(value), "change")["actions"] = actions
			if len(actions) == 1 {
				nested(resource(value), "change")["after"] = nil
			}
			setup(t).summary(t, "foundation", value, 3)
		})
	}
	for _, testCase := range []struct {
		name          string
		before, after bool
		code          int
	}{
		{"no-op", false, false, 0}, {"lock", false, true, 0}, {"unlock", true, false, 65},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			bucket := func(locked bool) object {
				return object{
					"force_destroy": false, "public_access_prevention": "enforced", "uniform_bucket_level_access": true,
					"soft_delete_policy": []any{object{"retention_duration_seconds": 0}},
					"lifecycle_rule":     []any{object{"action": []any{object{"type": "Delete"}}, "condition": []any{object{"age": 14}}}},
					"retention_policy":   []any{object{"retention_period": "604800", "is_locked": locked}},
				}
			}
			value := plan("google_storage_bucket", bucket(testCase.before), bucket(testCase.after))
			if testCase.name == "no-op" {
				nested(resource(value), "change")["actions"] = []string{"no-op"}
			}
			require.NotContains(t, setup(t).summary(t, "bootstrap", value, testCase.code), "604800")
		})
	}
	t.Run("ReorderedDisks", func(t *testing.T) {
		t.Parallel()
		boot := object{"device_name": "boot", "auto_delete": true}
		data := object{"device_name": "data", "source": "data", "mode": "READ_WRITE", "auto_delete": false}
		value := plan("google_compute_instance_template", object{"disk": []any{boot, data}}, object{"disk": []any{data, boot}})
		nested(resource(value), "change")["after_unknown"] = object{"disk": []any{object{"disk_size_gb": true}, object{"source_image": true}}}
		setup(t).summary(t, "foundation", value, 0)
	})
}

func TestPlanServiceExpiration(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, root string
		mutate     func(plan, condition object)
		code       int
	}{
		{"Success", "bootstrap", nil, 0},
		{"Success/AdditionalRestriction", "bootstrap", func(_ object, condition object) { condition["with_state"] = "LIVE" }, 0},
		{"Success/UnchangedRules", "bootstrap", func(p, _ object) {
			change := nested(resource(p), "change")
			change["before"] = change["after"]
		}, 0},
		{"Error/FoundationRoot", "foundation", nil, 65},
		{"Error/ServiceReleaseRoot", "service-release", nil, 65},
		{"Error/OtherAddress", "bootstrap", func(p, _ object) { resource(p)["address"] = "google_storage_bucket.backups" }, 65},
		{"Error/OtherBucket", "bootstrap", func(p, _ object) {
			for _, side := range []string{"before", "after"} {
				nested(resource(p), "change", side)["name"] = "agora-management-test-123456789012-backups"
			}
		}, 65},
		{"Error/OtherProject", "bootstrap", func(p, _ object) {
			for _, side := range []string{"before", "after"} {
				nested(resource(p), "change", side)["project"] = "agora-peer-test"
			}
		}, 65},
		{"Error/MissingRegistration", "bootstrap", func(p, _ object) { delete(p, "variables") }, 65},
		{"Error/RenamedBucket", "bootstrap", func(p, _ object) {
			nested(resource(p), "change", "after")["name"] = "agora-management-test-999999999999-tofu-state"
		}, 65},
		{"Error/ReplacedBucket", "bootstrap", func(p, _ object) {
			nested(resource(p), "change")["actions"] = []string{"delete", "create"}
		}, 65},
		{"Error/UnknownBucket", "bootstrap", func(p, _ object) {
			nested(resource(p), "change")["after_unknown"] = object{"name": true}
		}, 65},
		{"Error/UnknownRule", "bootstrap", func(p, _ object) {
			nested(resource(p), "change")["after_unknown"] = object{"lifecycle_rule": true}
		}, 65},
		{"Error/PrematureExpiry", "bootstrap", func(_ object, condition object) { condition["age"] = 1 }, 65},
		{"Error/MissingPrefix", "bootstrap", func(_ object, condition object) { delete(condition, "matches_prefix") }, 65},
		{"Error/BroadPrefix", "bootstrap", func(_ object, condition object) { condition["matches_prefix"] = []string{"services/", ""} }, 65},
		{"Error/MissingSuffix", "bootstrap", func(_ object, condition object) { delete(condition, "matches_suffix") }, 65},
		{"Error/BroadSuffix", "bootstrap", func(_ object, condition object) { condition["matches_suffix"] = []string{"/plan.tfplan", ".json"} }, 65},
		{"Error/RemovedRule", "bootstrap", func(p, _ object) {
			after := nested(resource(p), "change", "after")
			after["lifecycle_rule"] = after["lifecycle_rule"].([]any)[1:]
		}, 65},
		{"Error/ChangedRule", "bootstrap", func(p, _ object) {
			after := nested(resource(p), "change", "after")
			rule := after["lifecycle_rule"].([]any)[0].(object)
			rule["condition"] = []any{object{"days_since_noncurrent_time": 89, "num_newer_versions": 50}}
		}, 65},
		{"Error/WithdrawCleanup", "bootstrap", func(p, _ object) {
			change := nested(resource(p), "change")
			change["before"], change["after"] = change["after"], change["before"]
		}, 65},
		{"Error/ExtraRule", "bootstrap", func(p, _ object) {
			after := nested(resource(p), "change", "after")
			after["lifecycle_rule"] = append(after["lifecycle_rule"].([]any), fieldValue("action.0.type", "Delete"))
		}, 65},
		{"Error/WeakenedVersioning", "bootstrap", func(p, _ object) {
			nested(resource(p), "change", "after")["versioning"] = []any{object{"enabled": false}}
		}, 65},
		{"Error/WeakenedSoftDelete", "bootstrap", func(p, _ object) {
			nested(resource(p), "change", "after")["soft_delete_policy"] = []any{object{"retention_duration_seconds": 0}}
		}, 65},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			bucket := func() object {
				return object{
					"name": "agora-management-test-123456789012-tofu-state", "project": "agora-management-test",
					"versioning":         []any{object{"enabled": true}},
					"soft_delete_policy": []any{object{"retention_duration_seconds": 604800}},
					"lifecycle_rule": []any{object{
						"action":    []any{object{"type": "Delete"}},
						"condition": []any{object{"days_since_noncurrent_time": 90, "num_newer_versions": 50}},
					}},
				}
			}
			condition := object{
				"age": 2, "matches_prefix": []string{"services/"},
				"matches_suffix": []string{"/plan.tfplan", "/plan.metadata.json"},
				"with_state":     "ANY", "send_age_if_zero": false,
			}
			before, after := bucket(), bucket()
			after["lifecycle_rule"] = append(after["lifecycle_rule"].([]any), object{
				"action": []any{object{"type": "Delete", "storage_class": ""}}, "condition": []any{condition},
			})
			value := plan("google_storage_bucket", before, after)
			resource(value)["address"] = "google_storage_bucket.state"
			value["variables"] = object{"management_project_id": object{"value": "agora-management-test"}}
			if testCase.mutate != nil {
				testCase.mutate(value, condition)
			}
			setup(t).summary(t, testCase.root, value, testCase.code)
		})
	}
}
