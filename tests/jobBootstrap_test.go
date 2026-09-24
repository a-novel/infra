package tests_test

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

func jobBootstrapPlan(service, action string) object {
	changes := []any{}
	roles := []string{"migrations"}
	if service == "json-keys" {
		roles = append(roles, "rotatekeys")
	}
	for _, role := range roles {
		after := object{"project": "agora-" + service + "-test", "location": "europe-west1", "name": "agora-" + service + "-" + role, "deletion_protection": true}
		change := object{"actions": []string{action}, "before": nil, "after": after}
		if action != "create" {
			change["before"] = after
		}
		changes = append(changes, object{
			"mode": "managed", "type": "google_cloud_run_v2_job", "index": role,
			"address": `google_cloud_run_v2_job.application["` + role + `"]`, "change": change,
		})
	}
	return object{
		"format_version": "1.2", "resource_changes": changes,
		"variables": object{"project_id": object{"value": "agora-" + service + "-test"}, "service": object{"value": service}, "region": object{"value": "europe-west1"}},
	}
}

func TestJobBootstrapPolicy(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, action string
		mutate       func(object)
		code         int
	}{
		{"Create", "create", nil, 0},
		{"NoOp", "no-op", nil, 0},
		{"Update", "update", nil, 65},
		{"Delete", "delete", nil, 65},
		{"Replace", "create", func(p object) { nested(resource(p), "change")["actions"] = []string{"delete", "create"} }, 65},
		{"Import", "no-op", func(p object) { nested(resource(p), "change")["importing"] = object{"id": privateValue} }, 65},
		{"Move", "no-op", func(p object) { resource(p)["previous_address"] = privateValue }, 65},
		{"Deposed", "no-op", func(p object) { resource(p)["deposed"] = "abcd1234" }, 65},
		{"OtherResource", "create", func(p object) { resource(p)["type"] = "google_cloud_run_v2_service" }, 65},
		{"OtherAddress", "create", func(p object) { resource(p)["address"] = "google_cloud_run_v2_job.other" }, 65},
		{"OtherRole", "create", func(p object) { resource(p)["index"] = "init" }, 65},
		{"PeerProject", "create", func(p object) { nested(resource(p), "change", "after")["project"] = "agora-peer-test" }, 65},
		{"PeerRegion", "create", func(p object) { nested(resource(p), "change", "after")["location"] = "us-central1" }, 65},
		{"PeerName", "create", func(p object) { nested(resource(p), "change", "after")["name"] = "agora-peer-migrations" }, 65},
		{"Unprotected", "create", func(p object) { nested(resource(p), "change", "after")["deletion_protection"] = false }, 65},
		{"UnknownProject", "create", func(p object) { nested(resource(p), "change")["after_unknown"] = object{"project": true} }, 65},
	} {
		for _, service := range []string{"json-keys", "authentication"} {
			t.Run(service+"/"+testCase.name, func(t *testing.T) {
				t.Parallel()
				f := setup(t)
				f.env["SERVICE_JOB_BOOTSTRAP"], f.env["ALLOW_RESOURCE_DELETION"] = "true", "true"
				f.env["TOFU_STATE_SUFFIX"] = "services/agora-" + service + "-test"
				value := jobBootstrapPlan(service, testCase.action)
				if testCase.mutate != nil {
					testCase.mutate(value)
				}
				f.summary(t, "service-release", value, testCase.code)
			})
		}
	}
}

func TestJobBootstrapWorkflow(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, fail string
		code       int
	}{
		{"Success", "", 0},
		{"PartialApply", "apply", 1},
		{"ConvergenceFailure", "plan", 1},
		{"ChangedInputs", "inputs", 77},
		{"Disabled", "disabled", 77},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			f := setup(t)
			storageFixture(t, f)
			f.fake(t, "tofu", "fake-tofu.sh")
			stub, err := exec.LookPath("true")
			require.NoError(t, err)
			f.link(t, "git", stub)
			bucket := "agora-management-test-123-tofu-state"
			config := filepath.Join(f.dir, "inputs.json")
			writeJSON(t, config, object{
				"project_id": "agora-json-keys-test", "management_project_id": "agora-management-test", "region": "europe-west1",
				"state_bucket": bucket, "service": "json-keys", "private": privateValue,
			})
			f.env["FOUNDATION_CONFIG"] = `{"management_project_id":"agora-management-test","workload_project_id":"agora-production-test","region":"europe-west1","service_projects":{"json-keys":"agora-json-keys-test"}}`
			for key, value := range map[string]string{
				"MANAGEMENT_PROJECT_ID": "agora-management-test", "TOFU_STATE_SUFFIX": "services/agora-json-keys-test",
				"SERVICE_JOB_BOOTSTRAP_ENABLED": "true", "ROOT_NAME": "service-release", "STATE_BUCKET": bucket,
				"GITHUB_SHA": strings.Repeat("a", 40), "GITHUB_RUN_ID": "124", "GITHUB_RUN_ATTEMPT": "1",
				"PLAN_ID": "123-1", "TFVARS_FILE": config, "FAKE_TOFU_PLAN_CODE": "2",
				"FAKE_TOFU_PLAN_JSON": filepath.Join(f.dir, "create.json"), "FAKE_TOFU_CLEAN_PLAN_JSON": filepath.Join(f.dir, "noop.json"),
				"FAKE_TOFU_APPLIED": filepath.Join(f.dir, "applied"),
			} {
				f.env[key] = value
			}
			writeJSON(t, f.env["FAKE_TOFU_PLAN_JSON"], jobBootstrapPlan("json-keys", "create"))
			writeJSON(t, f.env["FAKE_TOFU_CLEAN_PLAN_JSON"], jobBootstrapPlan("json-keys", "no-op"))
			remote := filepath.Join(f.env["FAKE_GCS_ROOT"], bucket, f.env["TOFU_STATE_SUFFIX"], "release/plans", f.env["GITHUB_SHA"], "123-1")
			f.env["FAKE_TOFU_REQUIRE_ABSENT"] = filepath.Join(remote, "plan.tfplan")
			code, out := f.script(t, "create-reviewed-plan", "service-release", bucket, f.env["GITHUB_SHA"], "123-1", config)
			expectCode(t, 0, code, out)
			require.FileExists(t, f.env["FAKE_TOFU_REQUIRE_ABSENT"])
			switch testCase.fail {
			case "inputs":
				require.NoError(t, os.WriteFile(config, []byte(read(t, config)+"\n"), 0o600))
			case "disabled":
				delete(f.env, "SERVICE_JOB_BOOTSTRAP_ENABLED")
			default:
				f.env["FAKE_TOFU_FAIL_ACTION"] = testCase.fail
			}
			steps := loadWorkflow(t, "workflows/foundation.yaml").Jobs["execute"].Steps
			code, out = f.run(t, "bash", "-c", steps[stepIndex(t, steps, "./ops/apply-reviewed-plan.sh")].Run)
			expectCode(t, testCase.code, code, out)
			require.NotContains(t, out, "fixture-sensitive-diagnostic")
			published := filepath.Join(f.env["FAKE_GCS_ROOT"], bucket, f.env["TOFU_STATE_SUFFIX"], "release/config/00000000000000000124-00001.tfvars.json")
			if testCase.code == 0 {
				require.Equal(t, read(t, config), read(t, published))
			} else {
				require.NoFileExists(t, published)
			}
			if testCase.fail == "inputs" || testCase.fail == "disabled" {
				require.NoFileExists(t, f.env["FAKE_TOFU_APPLIED"])
				require.FileExists(t, f.env["FAKE_TOFU_REQUIRE_ABSENT"])
			} else {
				require.FileExists(t, f.env["FAKE_TOFU_APPLIED"], "retain the provider's state after success or partial failure")
				require.NoFileExists(t, f.env["FAKE_TOFU_REQUIRE_ABSENT"], "no replay after an apply attempt")
			}
		})
	}
}
