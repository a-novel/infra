package tests_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"google.golang.org/api/option"

	"github.com/a-novel/infra/internal/custody"
)

func TestLegacyRecoveryCustody(t *testing.T) {
	t.Parallel()
	for _, scenario := range []string{"Success", "Disabled", "WrongGeneration", "WrongScope", "WrongInputs", "MissingEnrollment", "WALDisabled", "PeerEnrollment", "UnknownService", "ActiveWriter", "RerunWriter", "WrongWriter", "GitHubUnavailable", "ExistingRecovery", "ExistingCompletion", "ConvergeFailed", "OutputFailed", "RecoveryFailed", "PublishFailed", "guard-ack", "completion-denied", "successor"} {
		t.Run(scenario, func(t *testing.T) {
			t.Parallel()
			f := setup(t)
			storageFixture(t, f)
			bucket := "agora-management-test-123-tofu-state"
			for key, value := range map[string]string{
				"ROOT_NAME": "foundation", "TOFU_STATE_SUFFIX": "", "STATE_BUCKET": bucket, "MANAGEMENT_PROJECT_ID": "agora-management-test",
				"LEGACY_DATABASE_RECOVERY_ENABLED": "true", "LEGACY_DATABASE_MAINTENANCE_ENABLED": "true", "PRODUCTION_RELEASES_ENABLED": "false",
				"GITHUB_REPOSITORY": "a-novel/infra", "GITHUB_REF": "refs/heads/master", "GITHUB_SHA": strings.Repeat("b", 40),
				"GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_WORKFLOW_REF": "a-novel/infra/.github/workflows/foundation.yaml@refs/heads/master",
				"GITHUB_RUN_ID": "124", "GITHUB_RUN_ATTEMPT": "1",
			} {
				f.env[key] = value
			}
			applyStorage(t, f, scenario)
			inputs := filepath.Join(f.dir, "recovery-inputs.json")
			config := object{"workload_project_id": "agora-production-test", "management_project_id": "agora-management-test", "database_zone": "europe-west1-d", "native_backups": object{"json-keys": object{"wal_archiving": true}}}
			switch scenario {
			case "MissingEnrollment":
				delete(config, "native_backups")
			case "WALDisabled":
				config["native_backups"] = object{"json-keys": object{"wal_archiving": false}}
			case "PeerEnrollment":
				config["native_backups"] = object{"authentication": object{"wal_archiving": true}}
			case "UnknownService":
				config["native_backups"] = object{"peer": object{"wal_archiving": true}}
			}
			writeJSON(t, inputs, config)
			f.env["FOUNDATION_CONFIG"] = read(t, inputs)
			prefix := filepath.Join(f.env["FAKE_GCS_ROOT"], bucket)
			guard := filepath.Join(prefix, "release/legacy-maintenance/operation.json")
			claim := filepath.Join(prefix, "release/legacy-maintenance/recoveries/42.json")
			completion := filepath.Join(prefix, "release/legacy-maintenance/completions/42.json")
			published := filepath.Join(prefix, "foundation/config/00000000000000000124-00001.tfvars.json")
			targets := []object{{"Project": "agora-production-test", "Zone": "europe-west1-d", "Service": "json-keys"}}
			if scenario == "WrongScope" {
				targets[0]["Project"] = "peer-project"
			}
			if scenario == "UnknownService" {
				targets[0]["Service"] = "peer"
			}
			writeJSON(t, guard, object{"schemaVersion": 1, "kind": "legacy-host-maintenance", "commit": strings.Repeat("a", 40), "planId": "122-1", "planSha256": strings.Repeat("c", 64), "runId": "123", "runAttempt": "1", "targets": targets})
			original := object{"id": 123, "run_attempt": 1, "status": "completed", "head_branch": "master", "head_sha": strings.Repeat("a", 40), "event": "workflow_dispatch", "path": ".github/workflows/foundation.yaml", "display_title": "foundation apply foundation by @operator", "updated_at": time.Now().Add(-10 * time.Minute).Format(time.RFC3339), "repository": "a-novel/infra"}
			generation := "42"
			switch scenario {
			case "Disabled":
				f.env["LEGACY_DATABASE_RECOVERY_ENABLED"] = ""
			case "WrongGeneration":
				generation = "43"
			case "WrongInputs":
				f.env["FOUNDATION_CONFIG"] = `{}`
			case "ActiveWriter":
				original["status"] = "in_progress"
			case "RerunWriter":
				original["run_attempt"] = 2
			case "WrongWriter":
				original["head_sha"] = strings.Repeat("d", 40)
			case "ExistingRecovery":
				writeJSON(t, claim, object{})
			case "ExistingCompletion":
				writeJSON(t, completion, object{})
			}
			var events []string
			execute := func(ctx context.Context, out io.Writer, command string, values ...string) error {
				switch command {
				case "gh":
					require.Equal(t, []string{"api", "--hostname", "github.com", "repos/a-novel/infra/actions/runs/123", "--jq"}, values[:5])
					if scenario == "GitHubUnavailable" {
						return errors.New(privateValue)
					}
					return json.NewEncoder(out).Encode(original)
				case "env":
					index := slices.Index(values, "./ops/tofu-gate.sh")
					require.Positive(t, index)
					gate := values[index+1:]
					require.Contains(t, []string{"converge", "output"}, gate[0], "recovery must never replay a plan or apply")
					require.Equal(t, []string{"foundation", bucket}, gate[1:3])
					require.Contains(t, values, "ALLOW_RESOURCE_DELETION=false")
					events = append(events, gate[0])
					if (scenario == "ConvergeFailed" && gate[0] == "converge") || (scenario == "OutputFailed" && gate[0] == "output") {
						return errors.New(privateValue)
					}
					if gate[0] == "output" {
						writeJSON(t, gate[3], object{})
					}
					return nil
				case "infra":
					require.Equal(t, []string{"database-release", "maintenance-recover"}, values[:2])
					require.Len(t, values, 7)
					require.FileExists(t, guard)
					require.FileExists(t, claim)
					require.JSONEq(t, jsonText(t, targets), read(t, values[2]))
					require.Equal(t, original["updated_at"], values[6])
					events = append(events, "recover")
					if scenario == "RecoveryFailed" {
						return errors.New(privateValue)
					}
					writeJSON(t, values[4], []object{{"service": "json-keys", "bootDiskId": "666"}})
					return nil
				default:
					require.Equal(t, "gcloud", command)
					require.Equal(t, []string{"storage", "cp"}, values[:2])
					events = append(events, "publish")
					require.FileExists(t, guard)
					if scenario == "PublishFailed" {
						return errors.New(privateValue)
					}
					cmd := exec.CommandContext(ctx, filepath.Join(f.bin, command), values...)
					cmd.Stdout, cmd.Stderr = out, out
					for key, value := range f.env {
						cmd.Env = append(cmd.Env, key+"="+value)
					}
					return cmd.Run()
				}
			}
			var output bytes.Buffer
			options := []option.ClientOption{option.WithEndpoint(f.env["TEST_STORAGE_ENDPOINT"]), option.WithoutAuthentication()}
			args := []string{"operation", "recover-legacy", bucket, generation, "RECOVER LEGACY " + generation, inputs}
			getenv := func(key string) string { return f.env[key] }
			code := custody.Run(t.Context(), args, getenv, execute, &output, &output, options...)
			require.NotContains(t, output.String(), privateValue)
			if scenario == "Success" {
				expectCode(t, 0, code, output.String())
				require.Equal(t, []string{"converge", "output", "recover", "publish"}, events)
				require.FileExists(t, completion)
				require.FileExists(t, published)
				require.NoFileExists(t, guard)
			} else {
				require.NotZero(t, code, output.String())
				require.FileExists(t, guard, "failed recovery must retain the exact maintenance hold")
				if !slices.Contains([]string{"RecoveryFailed", "PublishFailed", "completion-denied", "successor"}, scenario) {
					require.NotContains(t, events, "recover")
				}
			}
			if slices.Contains([]string{"Success", "RecoveryFailed", "PublishFailed", "guard-ack", "completion-denied", "successor"}, scenario) {
				require.FileExists(t, claim)
				events = nil
				require.NotZero(t, custody.Run(t.Context(), args, getenv, execute, &output, &output, options...))
				require.Empty(t, events, "uncertain or completed recovery must never replay")
			}
		})
	}
}
