package tests_test

import (
	"fmt"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

func scopedPlan(service, address, phase string) object {
	value := plan(strings.SplitN(address, ".", 2)[0], object{}, object{})
	resource(value)["address"] = address
	value["variables"] = object{"application_release": object{"value": object{"rollout": object{"services": []string{service}, "phase": phase}}}}
	return value
}

func TestReleaseScope(t *testing.T) {
	t.Parallel()
	for _, pair := range [][2]string{{"json_keys", "authentication"}, {"authentication", "json_keys"}} {
		selected, peer := pair[0], pair[1]
		for _, phase := range []string{"candidate", "active"} {
			for _, testCase := range []struct{ name, address, action string }{
				{"PeerTemplate", "google_cloud_run_v2_service." + peer + "[0]", "update"},
				{"PeerJob", fmt.Sprintf(`google_cloud_run_v2_job.application["%s_migrations"]`, peer), "update"},
				{"PeerBinding", "google_tags_location_tag_binding." + peer + "[0]", "replace"},
				{"NewResource", "google_cloud_run_v2_job.surprise[0]", "create"},
				{"Import", "google_cloud_run_v2_service." + peer + "[0]", "import"},
				{"Selected", "google_cloud_run_v2_service." + selected + "[0]", "update"},
			} {
				t.Run(selected+"/"+phase+"/"+testCase.name, func(t *testing.T) {
					t.Parallel()
					value := scopedPlan(selected, testCase.address, phase)
					change := nested(resource(value), "change")
					switch testCase.action {
					case "replace":
						change["actions"] = []string{"delete", "create"}
					case "create":
						change["actions"], change["before"] = []string{"create"}, nil
					case "import":
						change["actions"], change["importing"] = []string{"no-op"}, object{"id": privateValue}
					default:
						change["before"], change["after"] = object{"template": []any{object{"revision": "old", "memory": "512Mi"}}}, object{"template": []any{object{"revision": "old", "memory": "1Gi"}}}
					}
					f := setup(t)
					f.env["ALLOW_RESOURCE_DELETION"], f.env["RELEASE_PLAN_SERVICES"] = "true", fmt.Sprintf(`["%s"]`, selected)
					if testCase.name == "Selected" {
						peerNoop := resource(scopedPlan(selected, "google_cloud_run_v2_job.unselected[0]", phase))
						nested(peerNoop, "change")["actions"] = []string{"no-op"}
						value["resource_changes"] = append(value["resource_changes"].([]any), peerNoop)
						f.summary(t, "release", value, 0)
					} else {
						out := f.summary(t, "release", value, 65)
						require.Contains(t, out, "outside the selected service")
						require.NotRegexp(t, `512Mi|1Gi|surprise`, out)
					}
				})
			}
		}
	}
	for _, expected := range []string{"", `["json_keys"]`, `["json_keys","authentication"]`, "null", "not-json"} {
		t.Run("CompilerScope/"+expected, func(t *testing.T) {
			t.Parallel()
			f := setup(t)
			f.env["RELEASE_PLAN_SERVICES"] = expected
			code := 65
			if expected == "" {
				code = 0 // PR assessment evaluates the full graph.
			}
			value := scopedPlan("authentication", "google_cloud_run_v2_service.json_keys[0]", "candidate")
			f.summary(t, "release", value, code)
			if expected == `["json_keys","authentication"]` {
				nested(value, "variables", "application_release", "value", "rollout")["services"] = []string{"json_keys", "authentication"}
				resource(value)["address"] = "google_cloud_run_v2_service.other[0]"
				f.summary(t, "release", value, 0)
			}
		})
	}
}

func TestReleaseScheduleScope(t *testing.T) {
	t.Parallel()
	for _, phase := range []string{"candidate", "active"} {
		for _, failure := range []string{"", "target", "unknown", "frequency"} {
			t.Run(phase+"/"+failure, func(t *testing.T) {
				t.Parallel()
				value := schedulePlan(2, phase)
				change := nested(resource(value), "change")
				change["after_unknown"] = object{"state": true}
				for _, side := range []string{"before", "after"} {
					nested(change, side)["http_target"] = []any{object{"uri": "https://fixture"}}
				}
				nested(change, "before")["state"], nested(change, "after")["state"] = "ENABLED", nil
				switch failure {
				case "target":
					nested(change, "after")["http_target"] = []any{object{"uri": "https://other"}}
				case "unknown":
					nested(change, "after_unknown")["http_target"] = true
				case "frequency":
					nested(change, "after")["schedule"] = "* * * * *"
				}
				code := 0
				if failure != "" {
					code = 65
				}
				f := setup(t)
				f.env["RELEASE_PLAN_SERVICES"] = `["json_keys"]`
				f.summary(t, "release", value, code)
			})
		}
	}
}

func TestTofuGate(t *testing.T) {
	t.Parallel()
	for _, action := range []string{"plan", "assess", "apply", "converge", "drift"} {
		for _, root := range []string{"foundation", "release"} {
			t.Run(action+"/"+root, func(t *testing.T) {
				t.Parallel()
				f := setup(t)
				f.fake(t, "tofu", "fake-tofu.sh")
				f.link(t, "git", "/usr/bin/true")
				file := filepath.Join(f.dir, "plan.json")
				value := plan("future_resource", object{"deletion_protection": true}, object{"deletion_protection": false})
				if root == "release" {
					value = scopedPlan("authentication", "google_cloud_run_v2_service.json_keys[0]", "candidate")
					f.env["RELEASE_PLAN_SERVICES"] = `["authentication"]`
				}
				writeJSON(t, file, value)
				f.env["FAKE_TOFU_PLAN_JSON"], f.env["FAKE_TOFU_PLAN_CODE"] = file, "2"
				f.env["FAKE_TOFU_FAIL_ACTION"], f.env["ALLOW_RESOURCE_DELETION"] = "apply", "true"
				args := []string{action, root, "fixture-state"}
				if action == "plan" || action == "apply" {
					args = append(args, filepath.Join(f.dir, "saved.tfplan"))
					writeJSON(t, args[3], object{})
				}
				code, out := f.script(t, "tofu-gate", args...)
				expectCode(t, 65, code, out)
				require.NotContains(t, out, "fixture-sensitive-diagnostic")
			})
		}
	}
}
