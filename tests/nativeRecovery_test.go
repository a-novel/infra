package tests_test

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"

	infraworkflow "github.com/a-novel/infra/internal/workflow"
)

func nativeInputs(t *testing.T, f *sandbox) object {
	t.Helper()
	host := readJSON(t, filepath.Join(f.root, "environments/service-recovery/tests/fixture.json"))
	host["source_project"], host["management_project"], host["management_number"] = "agora-json-keys-test", "agora-management-test", "123456"
	host["protected_projects"] = []string{"agora-json-keys-test", "agora-management-test", "agora-production-test", "agora-authentication-test"}
	f.env["FOUNDATION_CONFIG"] = `{"management_project_id":"agora-management-test","workload_project_id":"agora-production-test","region":"europe-west1","service_projects":{"json-keys":"agora-json-keys-test","authentication":"agora-authentication-test"},"service_recovery_projects":{"a-novel-recovery-proof":"json-keys"}}`
	f.env["MANAGEMENT_PROJECT_ID"], f.env["STATE_BUCKET"] = "agora-management-test", "agora-management-test-123456-tofu-state"
	f.env["NATIVE_RECOVERY_PREPARATION_ENABLED"], f.env["RECOVERY_OPERATION"] = "true", "plan-native"
	f.env["GITHUB_EVENT_NAME"], f.env["GITHUB_WORKFLOW_REF"] = "workflow_dispatch", "a-novel/infra/.github/workflows/recovery.yaml@refs/heads/master"
	f.env["TOFU_STATE_SUFFIX"] = "services/a-novel-recovery-proof"
	return object{"state_bucket": f.env["STATE_BUCKET"], "recovery": host}
}

func TestNativeRecoveryInputs(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, field, env, value string
		valid                   bool
	}{
		{name: "Exact", valid: true},
		{name: "Restore/Exact", valid: true},
		{name: "Restore/SQL/Exact", valid: true},
		{name: "Restore/SQL/Disabled", env: "NATIVE_RECOVERY_SQL_ENABLED", value: "false"},
		{name: "Restore/SQL/FileConfirmation", env: "CONFIRM", value: "RESTORE-FILES a-novel-recovery-proof 42"},
		{name: "Restore/SQLConfirmationWithoutSelection", env: "CONFIRM", value: "RESTORE-SQL a-novel-recovery-proof 42"},
		{name: "Restore/Disabled", env: "NATIVE_RECOVERY_EXECUTION_ENABLED", value: "false"},
		{name: "Restore/WrongConfirmation", env: "CONFIRM", value: "RESTORE wrong"},
		{name: "Restore/PlanMixedIn", env: "RECOVERY_PLAN_ID", value: "123-1"},
		{name: "Disabled", env: "NATIVE_RECOVERY_PREPARATION_ENABLED", value: "false"},
		{name: "WrongWorkflow", env: "GITHUB_WORKFLOW_REF", value: "a-novel/infra/.github/workflows/foundation.yaml@refs/heads/master"},
		{name: "MissingPlan", env: "RECOVERY_OPERATION", value: "apply-native"},
		{name: "LegacySelector", env: "TARGET_RECEIPT", value: "123-1"},
		{name: "UnregisteredDestination", field: "project", value: "a-novel-recovery-peer"},
		{name: "PeerSource", field: "source_project", value: "agora-authentication-test"},
		{name: "PeerManagement", field: "management_number", value: "234567"},
		{name: "WrongRegion", field: "region", value: "us-central1"},
		{name: "UnqualifiedImage", field: "restore_image", value: "native-restore:latest"},
		{name: "MissingDatabaseIdentity", field: "system_id", value: ""},
		{name: "ImplicitBackup", field: "set", value: "latest"},
		{name: "UnknownField", field: "PROJECT", value: "a-novel-recovery-peer"},
		{name: "IncompleteProtection"},
		{name: "LegacyRegistration"},
		{name: "ReadOnlyWithWritesDisabled", valid: true},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			f := setup(t)
			config := nativeInputs(t, f)
			if strings.HasPrefix(testCase.name, "Restore/") {
				f.env["NATIVE_RECOVERY_PREPARATION_ENABLED"] = "false"
				f.env["NATIVE_RECOVERY_EXECUTION_ENABLED"], f.env["RECOVERY_OPERATION"] = "true", "restore-native"
				f.env["PREPARATION_GENERATION"], f.env["CONFIRM"] = "42", "RESTORE-FILES a-novel-recovery-proof 42"
			}
			if strings.HasPrefix(testCase.name, "Restore/SQL/") {
				nested(config, "recovery")["verify_sql"] = true
				f.env["NATIVE_RECOVERY_SQL_ENABLED"], f.env["CONFIRM"] = "true", "RESTORE-SQL a-novel-recovery-proof 42"
			}
			if testCase.field != "" {
				nested(config, "recovery")[testCase.field] = testCase.value
			}
			if testCase.env != "" {
				f.env[testCase.env] = testCase.value
			}
			if testCase.name == "IncompleteProtection" {
				nested(config, "recovery")["protected_projects"] = []string{"agora-management-test", "agora-json-keys-test"}
			}
			if testCase.name == "LegacyRegistration" {
				f.env["FOUNDATION_CONFIG"] = strings.TrimSuffix(f.env["FOUNDATION_CONFIG"], "}") + `,"recovery_mode":true}`
			}
			data, err := json.Marshal(object{"a-novel-recovery-proof": config})
			require.NoError(t, err)
			f.env["NATIVE_RECOVERY_CONFIG"] = string(data)
			file := filepath.Join(f.dir, "inputs.json")
			args := []string{"prepare", "a-novel-recovery-proof", file}
			if testCase.name == "ReadOnlyWithWritesDisabled" {
				writeJSON(t, file, config)
				f.env["NATIVE_RECOVERY_PREPARATION_ENABLED"] = "false"
				args = []string{"check", file, f.env["STATE_BUCKET"], f.env["TOFU_STATE_SUFFIX"]}
			}
			var output bytes.Buffer
			code := infraworkflow.RecoveryInputs(args, func(key string) string { return f.env[key] }, &output, io.Discard)
			require.Equal(t, testCase.valid, code == 0)
			if !testCase.valid {
				require.NoFileExists(t, file)
				require.Empty(t, output.String())
			}
		})
	}
}

func nativePlan(action string) object {
	return object{
		"format_version": "1.2", "variables": object{"recovery": object{"value": object{"project": "a-novel-recovery-proof"}}},
		"resource_changes": []any{object{
			"mode": "managed", "type": "google_compute_instance", "address": `google_compute_instance.recovery["selected"]`,
			"change": object{"actions": []string{action}, "after": object{"project": "a-novel-recovery-proof", "desired_status": "TERMINATED"}},
		}},
	}
}

func TestNativeRecoveryApply(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, fault string
		code        int
		guard       bool
	}{
		{"Prepared", "", 0, false},
		{"CompetingSource", "busy", 70, true},
		{"LostAdmission", "guard-ack", 70, true},
		{"ConvergenceFailure", "converge", 1, true},
		{"LostCompletion", "completion-ack", 70, true},
		{"SuccessorGuard", "successor", 70, true},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			f := inspectionFixture(t)
			input := nativeInputs(t, f)
			config := filepath.Join(f.dir, "inputs.json")
			writeJSON(t, config, input)
			writeJSON(t, filepath.Join(f.env["FAKE_GCS_ROOT"], f.env["STATE_BUCKET"], "foundation/recovery/services/a-novel-recovery-proof/default.tfstate"), object{"outputs": object{}})
			bucket, commit := f.env["STATE_BUCKET"], strings.Repeat("a", 40)
			f.env["GITHUB_REPOSITORY"], f.env["GITHUB_SHA"] = "a-novel/infra", commit
			f.env["GITHUB_RUN_ID"], f.env["GITHUB_RUN_ATTEMPT"] = "124", "1"
			f.env["ROOT_NAME"], f.env["RECOVERY_OPERATION"] = "service-recovery", "apply-native"
			f.env["FAKE_TOFU_PLAN_JSON"], f.env["FAKE_TOFU_PLAN_CODE"] = filepath.Join(f.dir, "plan.json"), "2"
			writeJSON(t, f.env["FAKE_TOFU_PLAN_JSON"], nativePlan("create"))
			f.env["FAKE_TOFU_CLEAN_PLAN_JSON"] = filepath.Join(f.dir, "clean.json")
			writeJSON(t, f.env["FAKE_TOFU_CLEAN_PLAN_JSON"], object{"format_version": "1.2", "variables": nativePlan("create")["variables"], "resource_changes": []any{}})
			f.env["FAKE_TOFU_APPLIED"] = filepath.Join(f.dir, "applied")
			f.env["FAKE_TOFU_REQUIRE_ABSENT"] = filepath.Join(f.env["FAKE_GCS_ROOT"], bucket, "foundation/plans/recovery", f.env["TOFU_STATE_SUFFIX"], commit, "123-1/plan.tfplan")
			code, output := f.script(t, "create-reviewed-plan", "service-recovery", bucket, commit, "123-1", config)
			expectCode(t, 0, code, output)
			applyStorage(t, f, testCase.fault)
			if testCase.fault == "converge" {
				f.env["FAKE_TOFU_FAIL_ACTION"] = "plan"
			}
			f.custody(t, testCase.code, "plan", "apply", bucket, "service-recovery", commit, "123-1", config)
			guard := filepath.Join(f.env["FAKE_GCS_ROOT"], bucket, "services/agora-json-keys-test/release/operation.json")
			_, err := os.Stat(guard)
			require.Equal(t, testCase.guard, err == nil)
			if testCase.code == 0 {
				completion := readJSON(t, filepath.Join(f.env["FAKE_GCS_ROOT"], strings.TrimSuffix(bucket, "-tofu-state")+"-deployment-receipts", "services/agora-json-keys-test/production/operations/42.json"))
				require.Equal(t, []any{"host-prepared", "a-novel-recovery-proof", "agora-json-keys-test"},
					[]any{completion["outcome"], nested(completion, "operation")["project_id"], nested(completion, "operation")["source_project"]})
				f.custody(t, 66, "plan", "apply", bucket, "service-recovery", commit, "123-1", config)
			}
		})
	}
}

func TestNativeRecoveryPolicy(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name   string
		mutate func(object)
		code   int
	}{
		{"Create", nil, 0},
		{"Update", func(c object) { c["actions"] = []string{"update"} }, 65},
		{"Replacement", func(c object) { c["actions"] = []string{"delete", "create"} }, 65},
		{"Import", func(c object) { c["importing"] = object{"id": "existing"} }, 65},
		{"PeerProject", func(c object) { nested(c, "after")["project"] = "agora-authentication-test" }, 65},
		{"RunningHost", func(c object) { nested(c, "after")["desired_status"] = "RUNNING" }, 65},
		{"UnknownProject", func(c object) { c["after_unknown"] = object{"project": true} }, 65},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			f := setup(t)
			f.env["TOFU_STATE_SUFFIX"], f.env["NATIVE_RECOVERY_PREPARATION"] = "services/a-novel-recovery-proof", "true"
			value := nativePlan("create")
			if testCase.mutate != nil {
				testCase.mutate(nested(resource(value), "change"))
			}
			f.summary(t, "service-recovery", value, testCase.code)
		})
	}
}

func TestNativeRecoveryWorkflow(t *testing.T) {
	t.Parallel()
	recovery := loadWorkflow(t, "workflows/recovery.yaml")
	job := recovery.Jobs["prepare-native"]
	selectInputs := stepIndex(t, job.Steps, "recovery-inputs prepare")
	auth := stepIndex(t, job.Steps, "google-github-actions/auth@")
	apply := stepIndex(t, job.Steps, "custody plan apply")
	privateDuringBuild := false
	for _, value := range job.Env {
		privateDuringBuild = privateDuringBuild || strings.Contains(value, "secrets.")
	}
	for _, testCase := range []struct {
		name      string
		got, want any
	}{
		{"ProtectedEnvironment", job.Environment, "production-recovery"},
		{"GlobalSerialization", recovery.Concurrency, object{"group": "production-infrastructure", "cancel-in-progress": false}},
		{"PreAuthenticationSelection", selectInputs < auth && auth < apply, true},
		{"BuildWithoutPrivateInputs", privateDuringBuild, false},
		{"ExplicitActivation", job.Env["NATIVE_RECOVERY_PREPARATION_ENABLED"], "${{ vars.NATIVE_RECOVERY_PREPARATION_ENABLED }}"},
		{"MasterOnly", strings.Contains(job.If, "github.ref == 'refs/heads/master'"), true},
		{"LegacyExcluded", strings.Contains(recovery.Jobs["recover"].If, "inputs.operation != 'plan-native' && inputs.operation != 'apply-native'"), true},
		{"BoundInputs", job.Steps[apply].Env["TOFU_VAR_FILE"], "${{ steps.scope.outputs.file }}"},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			require.Equal(t, testCase.want, testCase.got)
		})
	}
}

func TestNativeRecoveryInspection(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, fault, mode string
		code              int
	}{
		{"Assessment", "", "assess", 0},
		{"Drift", "", "drift", 0},
		{"MissingConfiguration", "config", "assess", 70},
		{"UnregisteredState", "orphan", "assess", 70},
		{"SourceGuard", "guard", "assess", 70},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			f := inspectionFixture(t)
			config := nativeInputs(t, f)
			f.env["NATIVE_RECOVERY_PREPARATION_ENABLED"] = "false"
			f.env["FAKE_GATE_FILES"] = "service-recovery"
			store := filepath.Join(f.env["FAKE_GCS_ROOT"], f.env["STATE_BUCKET"])
			var registration object
			require.NoError(t, json.Unmarshal([]byte(f.env["FOUNDATION_CONFIG"]), &registration))
			writeJSON(t, filepath.Join(store, "foundation/config/00000000000000000001-00001.tfvars.json"), registration)
			destination := "a-novel-recovery-proof"
			if testCase.fault == "orphan" {
				destination = "a-novel-recovery-peer"
			}
			directory := filepath.Join(store, "foundation/recovery/services", destination)
			writeJSON(t, filepath.Join(directory, "default.tfstate"), object{})
			if testCase.fault != "config" {
				writeJSON(t, filepath.Join(directory, "config/00000000000000000001-00001.tfvars.json"), config)
			}
			if testCase.fault == "guard" {
				writeJSON(t, filepath.Join(store, "services/agora-json-keys-test/release/operation.json"), object{})
			}
			args := []string{"inspect", "assess", "a-novel/infra", "93", f.env["FAKE_GATE_HEAD"], f.env["FAKE_GATE_BASE"], f.dir, f.env["STATE_BUCKET"], filepath.Join(f.dir, "verdict.json")}
			if testCase.mode == "drift" {
				args = []string{"inspect", "drift", f.env["STATE_BUCKET"]}
			}
			code, output := f.run(t, "infra", args...)
			expectCode(t, testCase.code, code, output)
			if testCase.code == 0 {
				require.Contains(t, read(t, f.env["FAKE_TOFU_CALLS"]), "/service-recovery plan ")
			}
		})
	}
}
