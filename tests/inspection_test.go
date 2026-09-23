package tests_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestServiceInspection(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, mutation, mode string
		code, plans          int
		approval             bool
	}{
		{"UnregisteredEmpty", "unregistered", "assess", 0, 0, false},
		{"RegisteredEmpty", "empty", "assess", 0, 0, false},
		{"OneInitialized", "", "assess", 0, 1, false},
		{"BothInitialized", "both", "assess", 0, 2, false},
		{"StateWithoutConfig", "no-config", "assess", 70, 0, false},
		{"ConfigWithoutState", "no-state", "assess", 70, 0, false},
		{"UnregisteredState", "orphan", "assess", 70, 0, false},
		{"UnexpectedWorkspace", "workspace", "assess", 70, 0, false},
		{"MismatchedProject", "project", "assess", 70, 0, false},
		{"MismatchedRegion", "region", "assess", 70, 0, false},
		{"DuplicateRegistration", "duplicate", "assess", 70, 0, false},
		{"NullRegistration", "null", "assess", 70, 0, false},
		{"ListDenied", "list-denied", "assess", 70, 0, false},
		{"ReadDenied", "read-denied", "assess", 70, 0, false},
		{"Deletion", "deletion", "assess", 0, 1, true},
		{"PlanFailure", "plan-failure", "assess", 70, 1, false},
		{"DriftFleet", "both", "drift", 0, 3, false},
		{"DriftChanges", "deletion", "drift", 2, 1, false},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			f := inspectionFixture(t)
			bucket := "agora-management-test-123-tofu-state"
			storage := filepath.Join(f.env["FAKE_GCS_ROOT"], bucket, "foundation")
			projects := object{"json-keys": "agora-json-keys-test", "authentication": "agora-authentication-test"}
			registration := object{"service_projects": projects, "management_project_id": "agora-management-test", "workload_project_id": "agora-legacy-test", "region": "europe-west1"}
			services := []string{"json-keys"}
			switch testCase.mutation {
			case "unregistered":
				delete(registration, "service_projects")
				fallthrough
			case "empty":
				services = nil
			case "both":
				services = append(services, "authentication")
			case "duplicate":
				projects["authentication"] = projects["json-keys"]
			case "null":
				registration["service_projects"] = nil
			case "orphan":
				writeJSON(t, filepath.Join(storage, "services/agora-peer-test/default.tfstate"), object{})
			case "workspace":
				writeJSON(t, filepath.Join(storage, "services/agora-json-keys-test/other.tfstate"), object{})
			case "list-denied", "read-denied":
				f.env["FAKE_GCS_"+strings.ToUpper(strings.TrimSuffix(testCase.mutation, "-denied"))+"_FAILURE"] = "true"
			case "deletion":
				f.env["FAKE_TOFU_PLAN_JSON"] = filepath.Join(f.root, "tests/fixtures/plans/protected.json")
				f.env["FAKE_TOFU_PLAN_CODE"] = "2"
			case "plan-failure":
				f.env["FAKE_TOFU_FAIL_ACTION"] = "plan"
			}
			writeJSON(t, filepath.Join(storage, "config/00000000000000000001-00001.tfvars.json"), registration)
			for _, service := range services {
				project := "agora-" + service + "-test"
				directory := filepath.Join(storage, "services", project)
				config := object{"service": service, "project_id": project, "management_project_id": "agora-management-test", "region": "europe-west1", "state_bucket": bucket, "private": privateValue}
				if testCase.mutation == "project" {
					config["project_id"] = "agora-peer-test"
				}
				if testCase.mutation == "region" {
					config["region"] = "us-central1"
				}
				if testCase.mutation != "no-state" {
					writeJSON(t, filepath.Join(directory, "default.tfstate"), object{})
				}
				if testCase.mutation != "no-config" {
					writeJSON(t, filepath.Join(directory, "config/00000000000000000001-00001.tfvars.json"), config)
				}
			}
			output := filepath.Join(f.dir, "assessment.json")
			args := []string{"inspect", "assess", "a-novel/infra", "93", f.env["FAKE_GATE_HEAD"], f.env["FAKE_GATE_BASE"], f.dir, bucket, output}
			if testCase.mode == "drift" {
				args = []string{"inspect", "drift", bucket}
			}
			code, out := f.run(t, "infra", args...)
			expectCode(t, testCase.code, code, out)
			calls, err := os.ReadFile(f.env["FAKE_TOFU_CALLS"])
			if err != nil {
				require.ErrorIs(t, err, os.ErrNotExist)
			}
			require.Equal(t, testCase.plans, strings.Count(string(calls), " plan "), string(calls))
			if code == 0 && testCase.mode == "assess" {
				result := readJSON(t, output)
				require.Equal(t, []any{testCase.approval, false}, []any{result["approvalRequired"], result["firstLaunch"]})
			} else {
				require.NoFileExists(t, output)
			}
			require.NotContains(t, string(calls)+out, privateValue)
			require.NotContains(t, string(calls), " apply ")
		})
	}
}

func TestInspectionAuthorization(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, candidate, files, auth, config string
		code                                 int
		first                                bool
	}{
		{"FirstImage", "--image-only", "image", "0", "", 0, true},
		{"EmptyImage", "--image-only", "image", "0", `{"application_release":null}`, 0, true},
		{"ActiveImage", "--image-only", "image", "0", `{"application_release":{}}`, 0, false},
		{"UnauthorizedImage", "--image-only", "image", "77", "", 77, false},
		{"ImageCannotPlan", "--image-only", "service", "0", "", 77, false},
		{"DirtyCandidate", "dirty", "service", "0", "", 65, false},
		{"StalePR", "stale", "service", "0", "", 77, false},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			f := inspectionFixture(t)
			f.env["FAKE_GATE_FILES"], f.env["FAKE_IMAGE_AUTH_CODE"] = testCase.files, testCase.auth
			candidate, base := testCase.candidate, f.env["FAKE_GATE_BASE"]
			if candidate == "dirty" {
				candidate, f.env["FAKE_GIT_DIRTY"] = f.dir, " M main.tf"
			}
			if candidate == "stale" {
				candidate, base = f.dir, strings.Repeat("c", 40)
			}
			if testCase.config != "" {
				file := filepath.Join(f.env["FAKE_GCS_ROOT"], "agora-state-test/release/config/00000000000000000001-00001.tfvars.json")
				require.NoError(t, os.MkdirAll(filepath.Dir(file), 0o700))
				require.NoError(t, os.WriteFile(file, []byte(testCase.config), 0o600))
			}
			output := filepath.Join(f.dir, "assessment.json")
			code, out := f.run(t, "infra", "inspect", "assess", "a-novel/infra", "93", f.env["FAKE_GATE_HEAD"], base, candidate, "agora-state-test", output)
			expectCode(t, testCase.code, code, out)
			require.NoFileExists(t, f.env["FAKE_TOFU_CALLS"])
			if code == 0 {
				result := readJSON(t, output)
				require.Equal(t, []any{testCase.first, testCase.first}, []any{result["firstLaunch"], result["approvalRequired"]})
			} else {
				require.NoFileExists(t, output)
			}
		})
	}
}

func inspectionFixture(t *testing.T) *sandbox {
	t.Helper()
	f := setup(t)
	f.command(t, "infra")
	f.command(t, "git")
	f.fake(t, "gh", "fake-deletion-gate-gh.sh")
	f.fake(t, "gcloud", "fake-gcloud-storage.sh")
	f.fake(t, "tofu", "fake-tofu.sh")
	f.env["FAKE_GATE_HEAD"], f.env["FAKE_GATE_BASE"] = strings.Repeat("a", 40), strings.Repeat("b", 40)
	f.env["FAKE_GATE_FILES"], f.env["FAKE_GCS_ROOT"] = "service", filepath.Join(f.dir, "storage")
	f.env["FAKE_TOFU_PLAN_CODE"], f.env["FAKE_TOFU_PLAN_JSON"] = "0", filepath.Join(f.root, "tests/fixtures/plans/no-changes.json")
	f.env["FAKE_TOFU_CALLS"] = filepath.Join(f.dir, "tofu-calls")
	f.env["MANAGEMENT_PROJECT_ID"], f.env["SERVICE_FOUNDATIONS_ENABLED"] = "agora-management-test", "false"
	f.env["TOFU_STATE_SUFFIX"], f.env["FOUNDATION_CONFIG"] = "recovery/agora-peer-test", `{"service_projects":{"json-keys":"agora-peer-test"}}`
	return f
}
