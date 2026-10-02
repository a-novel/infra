package tests_test

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/a-novel/infra/internal/inspection"
)

func TestPendingFoundationInspection(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, mutation string
		code, plans    int
	}{
		{"PendingFoundation", "", 0, 1},
		{"StandardIgnoresPending", "standard", 0, 1},
		{"DriftIgnoresPending", "drift", 0, 1},
		{"DeletionStillRequiresApproval", "deletion", 0, 1},
		{"RegisteredPartialShell", "empty-service", 0, 0},
		{"ConvergedServiceInputs", "service", 0, 1},
		{"ServiceMissingInputs", "no-config", 70, 0},
		{"HeldServiceOperation", "guard", 70, 0},
		{"UnregisteredServiceState", "orphan", 70, 0},
		{"MissingPending", "missing", 65, 0},
		{"InvalidJSON", "json", 65, 0},
		{"NullPending", "null", 65, 0},
		{"InvalidManagement", "management", 65, 0},
		{"InvalidBackend", "bucket", 65, 0},
		{"InvalidServiceRegistration", "registration", 65, 0},
		{"NonDispatch", "event", 77, 0},
		{"UntrustedWorkflow", "workflow", 77, 0},
		{"WrongBase", "base", 77, 0},
		{"WrongOperation", "operation", 77, 0},
		{"ImageOnly", "image", 77, 0},
		{"DirtyCandidate", "dirty", 65, 0},
		{"StaleCandidate", "stale", 77, 0},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			f := inspectionFixture(t)
			bucket := "agora-management-test-123-tofu-state"
			storage := filepath.Join(f.env["FAKE_GCS_ROOT"], bucket)
			converged := object{"management_project_id": "agora-management-test", "private": "converged-" + privateValue}
			configFile := filepath.Join(storage, "foundation/config/00000000000000000001-00001.tfvars.json")
			writeJSON(t, configFile, converged)
			original := read(t, configFile)
			pending := object{"management_project_id": "agora-management-test", "workload_project_id": "agora-legacy-test", "region": "europe-west1", "service_projects": object{"json-keys": "agora-json-keys-test"}, "private": privateValue}
			f.env["GITHUB_EVENT_NAME"] = "workflow_dispatch"
			f.env["GITHUB_WORKFLOW_REF"] = "a-novel/infra/.github/workflows/drift.yaml@refs/heads/master"
			f.env["GITHUB_SHA"] = f.env["FAKE_GATE_BASE"]
			f.env["ASSESSMENT_OPERATION"] = "assess-pending-foundation"
			f.env["FAKE_GATE_FILES"] = "foundation"
			f.env["FAKE_GCS_MANAGED_FOLDERS"] = "services/agora-json-keys-test/release/"
			mode, candidate := "assess-pending-foundation", f.dir
			serviceConfig := object{"service": "json-keys", "project_id": "agora-json-keys-test", "management_project_id": "agora-management-test", "region": "europe-west1", "state_bucket": bucket, "private": "service-" + privateValue}
			switch testCase.mutation {
			case "standard", "drift":
				mode = "assess"
				f.env["FAKE_GCS_MANAGED_FOLDERS"] = ""
			case "deletion":
				f.env["FAKE_TOFU_PLAN_CODE"] = "2"
				f.env["FAKE_TOFU_PLAN_JSON"] = filepath.Join(f.root, "tests/fixtures/plans/protected.json")
			case "service", "no-config", "guard", "orphan", "empty-service":
				f.env["FAKE_GATE_FILES"] = "service"
				dir := filepath.Join(storage, "foundation/services/agora-json-keys-test")
				if testCase.mutation != "empty-service" {
					writeJSON(t, filepath.Join(dir, "default.tfstate"), object{})
				}
				if testCase.mutation != "no-config" && testCase.mutation != "empty-service" {
					writeJSON(t, filepath.Join(dir, "config/00000000000000000001-00001.tfvars.json"), serviceConfig)
				}
				if testCase.mutation == "guard" {
					writeJSON(t, filepath.Join(storage, "services/agora-json-keys-test/release/operation.json"), object{})
				}
				if testCase.mutation == "orphan" {
					writeJSON(t, filepath.Join(storage, "foundation/services/agora-peer-test/default.tfstate"), object{})
				}
			case "management":
				pending["management_project_id"] = "agora-other-test"
			case "bucket":
				bucket = "agora-other-test-123-tofu-state"
			case "registration":
				pending["service_projects"] = object{"peer": "agora-peer-test"}
			case "event":
				f.env["GITHUB_EVENT_NAME"] = "schedule"
			case "workflow":
				f.env["GITHUB_WORKFLOW_REF"] = "a-novel/infra/.github/workflows/drift.yaml@refs/heads/candidate"
			case "base":
				f.env["GITHUB_SHA"] = strings.Repeat("c", 40)
			case "operation":
				f.env["ASSESSMENT_OPERATION"] = "assess-pull-request"
			case "image":
				candidate = "--image-only"
			case "dirty":
				f.env["FAKE_GIT_DIRTY"] = " M main.tf"
			case "stale":
				f.env["FAKE_GATE_LIVE_BASE"] = strings.Repeat("c", 40)
			}
			data, err := json.Marshal(pending)
			require.NoError(t, err)
			f.env["PENDING_FOUNDATION_CONFIG"] = string(data)
			switch testCase.mutation {
			case "missing":
				f.env["PENDING_FOUNDATION_CONFIG"] = ""
			case "json":
				f.env["PENDING_FOUNDATION_CONFIG"] = privateValue
			case "null":
				f.env["PENDING_FOUNDATION_CONFIG"] = "null"
			}
			output := filepath.Join(f.dir, "assessment.json")
			args := []string{mode, "a-novel/infra", "93", f.env["FAKE_GATE_HEAD"], f.env["FAKE_GATE_BASE"], candidate, bucket, output}
			if testCase.mutation == "drift" {
				args = []string{"drift", bucket}
			}
			var stdout, stderr bytes.Buffer
			files := []string{}
			code := inspection.Run(t.Context(), args, func(key string) string { return f.env[key] },
				func(ctx context.Context, env []string, name string, args ...string) ([]byte, error) {
					if filepath.Base(name) == "tofu-gate.sh" || filepath.Base(name) == "resource-deletion-impact.sh" {
						name = filepath.Join(f.root, "ops", filepath.Base(name))
					}
					if filepath.Base(name) == "tofu-gate.sh" {
						for _, entry := range env {
							if file, ok := strings.CutPrefix(entry, "TOFU_VAR_FILE="); ok {
								files = append(files, file)
								stat, err := os.Stat(file)
								require.NoError(t, err)
								require.Equal(t, os.FileMode(0o600), stat.Mode().Perm())
								expected := pending
								if mode == "assess" {
									expected = converged
								} else if testCase.mutation == "service" {
									expected = serviceConfig
								}
								require.Equal(t, expected, readJSON(t, file))
							}
						}
					}
					if !filepath.IsAbs(name) {
						name = filepath.Join(f.bin, name)
					}
					command := exec.CommandContext(ctx, name, args...)
					command.Dir = f.root
					for key, value := range f.env {
						command.Env = append(command.Env, key+"="+value)
					}
					command.Env = append(command.Env, env...)
					return command.Output()
				}, &stdout, &stderr)
			require.Equal(t, testCase.code, code, stderr.String())
			require.Len(t, files, testCase.plans)
			for _, file := range files {
				require.NoFileExists(t, file)
			}
			require.Equal(t, original, read(t, configFile))
			require.NotContains(t, stdout.String()+stderr.String(), privateValue)
			if code == 0 && testCase.mutation != "drift" {
				verdict := readJSON(t, output)
				require.Len(t, verdict, 7)
				require.Equal(t, testCase.mutation == "deletion", verdict["approvalRequired"])
			} else {
				require.NoFileExists(t, output)
			}
			if calls, err := os.ReadFile(f.env["FAKE_GCS_CALLS"]); err == nil {
				require.NotContains(t, string(calls), "storage rm")
				for line := range strings.SplitSeq(string(calls), "\n") {
					if arguments, ok := strings.CutPrefix(line, "storage cp "); ok {
						require.True(t, strings.HasPrefix(arguments, "gs://"), "Only downloads are allowed: %s", line)
					}
				}
			}
		})
	}
}
