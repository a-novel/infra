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
