package tests_test

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os/exec"
	"path/filepath"
	"slices"
	"testing"

	"github.com/stretchr/testify/require"
	"google.golang.org/api/option"

	"github.com/a-novel/infra/internal/custody"
)

func TestLegacyMaintenanceCustody(t *testing.T) {
	t.Parallel()
	for _, scenario := range []string{"Success", "NoOp", "PlanRefused", "ApplyFailed", "ConvergeFailed", "OutputFailed", "ReplacementFailed", "busy", "guard-ack", "completion-denied", "successor"} {
		t.Run(scenario, func(t *testing.T) {
			t.Parallel()
			f, args, metadata := planFixture(t, "foundation", "")
			f.env["ROOT_NAME"] = "foundation"
			f.env["GITHUB_SHA"], f.env["GITHUB_RUN_ID"], f.env["GITHUB_RUN_ATTEMPT"] = args[2], "124", "1"
			inputs := filepath.Join(f.dir, "inputs.json")
			writeJSON(t, inputs, object{"workload_project_id": "agora-production-test"})
			applyStorage(t, f, scenario)
			remotePlan := filepath.Join(filepath.Dir(metadata), "plan.tfplan")
			guard := filepath.Join(f.env["FAKE_GCS_ROOT"], args[0], "release/legacy-maintenance/operation.json")
			completion := filepath.Join(f.env["FAKE_GCS_ROOT"], args[0], "release/legacy-maintenance/completions/42.json")
			var events []string
			execute := func(ctx context.Context, out io.Writer, command string, values ...string) error {
				if command == "env" {
					index := slices.Index(values, "./ops/tofu-gate.sh")
					require.NotEqual(t, -1, index)
					gate := values[index+1:]
					events = append(events, gate[0])
					if gate[0] == "inspect" {
						writeJSON(t, gate[3]+".json", object{})
						return nil
					}
					require.NoFileExists(t, remotePlan)
					if scenario != "NoOp" {
						require.FileExists(t, guard)
					}
					if (scenario == "ApplyFailed" && gate[0] == "apply") || (scenario == "ConvergeFailed" && gate[0] == "converge") || (scenario == "OutputFailed" && gate[0] == "output") {
						return errors.New(privateValue)
					}
					if gate[0] == "output" {
						writeJSON(t, gate[3], object{})
					}
					return nil
				}
				if command == "infra" {
					require.Equal(t, "database-release", values[0])
					events = append(events, values[1])
					if values[1] == "maintenance-plan" {
						require.FileExists(t, remotePlan)
						require.NoFileExists(t, guard)
						if scenario == "PlanRefused" {
							return errors.New(privateValue)
						}
						targets := []object{{"Project": "agora-production-test", "Service": "json-keys"}}
						if scenario == "NoOp" {
							targets = nil
						}
						writeJSON(t, values[4], targets)
					} else {
						require.Equal(t, "maintenance-replace", values[1])
						require.FileExists(t, guard)
						require.NoFileExists(t, remotePlan)
						if scenario == "ReplacementFailed" {
							return errors.New(privateValue)
						}
						writeJSON(t, values[4], []object{{"service": "json-keys", "newInstanceId": "456"}})
					}
					return nil
				}
				require.Equal(t, "gcloud", command)
				require.Equal(t, "storage", values[0])
				cmd := exec.CommandContext(ctx, filepath.Join(f.bin, command), values...)
				cmd.Stdout, cmd.Stderr = out, out
				for key, value := range f.env {
					cmd.Env = append(cmd.Env, key+"="+value)
				}
				return cmd.Run()
			}
			var output bytes.Buffer
			getenv := func(key string) string { return f.env[key] }
			options := []option.ClientOption{option.WithEndpoint(f.env["TEST_STORAGE_ENDPOINT"]), option.WithoutAuthentication()}
			call := append([]string{"plan", "apply"}, args[:4]...)
			call = append(call, inputs)
			code := custody.Run(t.Context(), call, getenv, execute, &output, &output, options...)
			require.NotContains(t, output.String(), privateValue)
			if scenario == "Success" || scenario == "NoOp" {
				expectCode(t, 0, code, output.String())
				require.NoFileExists(t, guard)
				require.NoFileExists(t, remotePlan)
				if scenario == "Success" {
					require.Equal(t, []string{"inspect", "maintenance-plan", "apply", "converge", "output", "maintenance-replace"}, events)
					require.FileExists(t, completion)
				} else {
					require.Equal(t, []string{"inspect", "maintenance-plan", "apply", "converge"}, events)
				}
			} else {
				require.NotZero(t, code, output.String())
				if scenario != "PlanRefused" {
					require.FileExists(t, guard, "uncertainty must retain the hold")
				}
				if slices.Contains([]string{"PlanRefused", "busy", "guard-ack"}, scenario) {
					require.FileExists(t, remotePlan)
					require.NotContains(t, events, "apply")
				}
			}
			check := custody.Run(t.Context(), []string{"operation", "check-legacy", args[0]}, getenv, execute, &output, &output, options...)
			if scenario == "Success" || scenario == "NoOp" || scenario == "PlanRefused" {
				expectCode(t, 0, check, output.String())
			} else {
				expectCode(t, 70, check, output.String())
			}
		})
	}
}

func TestLegacyMaintenanceWorkflowBoundary(t *testing.T) {
	t.Parallel()
	foundation := loadWorkflow(t, "workflows/foundation.yaml")
	job := foundation.Jobs["execute"]
	apply := job.Steps[stepIndex(t, job.Steps, "infra custody plan apply")]
	require.Equal(t, "${{ vars.LEGACY_DATABASE_MAINTENANCE_ENABLED }}", apply.Env["LEGACY_DATABASE_MAINTENANCE_ENABLED"])
	require.Equal(t, "${{ vars.PRODUCTION_RELEASES_ENABLED }}", apply.Env["PRODUCTION_RELEASES_ENABLED"])
	require.Equal(t, "production-foundation", job.Environment)
	recovery := job.Steps[stepIndex(t, job.Steps, "infra custody operation recover-legacy")]
	require.Equal(t, "inputs.operation == 'recover-legacy'", recovery.If)
	for _, flag := range []string{"LEGACY_DATABASE_RECOVERY_ENABLED", "LEGACY_DATABASE_MAINTENANCE_ENABLED", "PRODUCTION_RELEASES_ENABLED"} {
		require.Equal(t, "${{ vars."+flag+" }}", recovery.Env[flag])
	}
	require.Equal(t, object{"group": "production-infrastructure", "cancel-in-progress": false}, foundation.Concurrency)
	release := loadWorkflow(t, "workflows/release.yaml").Jobs["release"]
	check := stepIndex(t, release.Steps, "infra custody operation check-legacy")
	require.Less(t, stepIndex(t, release.Steps, "google-github-actions/auth@"), check)
	for _, mutation := range []string{"infra compile-release", "release-orchestrator.sh", "database-release recover-first-launch"} {
		require.Less(t, check, stepIndex(t, release.Steps, mutation))
	}
}
