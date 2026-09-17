package tests_test

import (
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/a-novel/infra/internal/release"
)

func TestSelectedReleaseGraph(t *testing.T) {
	t.Parallel()
	for service, selected := range map[string][]string{
		"json_keys":      {"json-migrations", "json-rotation", "recovery-verification", "json-smoke", "json-traffic"},
		"authentication": {"authentication-migrations", "recovery-verification", "authentication-initialization", "authentication-smoke", "authentication-traffic"},
	} {
		steps := append([]string{"preflight", "promote", "plan", "database", "candidate"}, selected...)
		steps = append(steps, "active", "receipt")
		for index, failure := range append([]string{""}, steps...) {
			name := "Error/" + failure
			if failure == "" {
				name = "Success"
			}
			t.Run(service+"/"+name, func(t *testing.T) {
				t.Parallel()
				f := setup(t)
				input := filepath.Join(f.dir, "release.json")
				writeJSON(t, input, object{"mode": "service", "services": []string{service}})
				f.env["RELEASE_TEST_LOG"], f.env["RELEASE_TEST_FAIL_STEP"] = filepath.Join(f.dir, "calls"), failure
				code, out := f.script(t, "release-orchestrator", filepath.Join(f.root, "tests/fixtures/fake-release-driver.sh"), input)
				expected, status := steps, 0
				if failure != "" {
					status = 42
					expected = append([]string{}, steps[:index]...)
					if index >= 4 {
						expected = append(expected, "rollback")
					}
				}
				expectCode(t, status, code, out)
				require.Equal(t, strings.Join(expected, "\n")+"\n", read(t, f.env["RELEASE_TEST_LOG"]))
			})
		}
	}
}

func TestReleaseRejectsScope(t *testing.T) {
	t.Parallel()
	for name, scope := range map[string]object{
		"missing": {}, "two-services": {"mode": "service", "services": []string{"json_keys", "authentication"}},
		"unknown": {"mode": "service", "services": []string{"shell"}}, "empty-maintenance": {"mode": "maintenance", "services": []string{}},
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			f := setup(t)
			input := filepath.Join(f.dir, "release.json")
			writeJSON(t, input, scope)
			f.env["RELEASE_TEST_LOG"] = filepath.Join(f.dir, "calls")
			code, out := f.script(t, "release-orchestrator", filepath.Join(f.root, "tests/fixtures/fake-release-driver.sh"), input)
			expectCode(t, 65, code, out)
			require.NoFileExists(t, f.env["RELEASE_TEST_LOG"])
		})
	}
}

func TestSelectedRecoveryJobs(t *testing.T) {
	t.Parallel()
	for service, operation := range map[string]string{"json_keys": "JsonKeys", "authentication": "Authentication"} {
		t.Run(service, func(t *testing.T) {
			t.Parallel()
			f := compiledFixture(t)
			f.change(service, true)
			f.compile(t)
			operations := nested(f.receipt, "operations")
			writeJSON(t, filepath.Join(f.files[3], "operations.json"), operations)
			var calls []invocation
			for _, kind := range []string{"backup", "restore", "monitor"} {
				job, key := "agora-postgres-"+kind+"-"+strings.ReplaceAll(service, "_", "-"), "postgresBackup"+operation
				if kind == "restore" {
					key = "postgresRestore" + operation
				}
				if kind == "monitor" {
					job, key = "agora-postgres-backup-monitor", "postgresBackupMonitor"
				}
				calls = append(calls, invocation{Name: "gcloud", Args: []string{"run", "jobs", "execute", job, "--project=agora-production-test", "--region=europe-west1", "--wait", "--quiet", "--format=value(metadata.name)"}, Output: job + "-test"})
				nested(operations, "executions")[key] = job + "-test"
			}
			f.driver(t, "recovery-verification", calls)
			require.Equal(t, operations, readJSON(t, filepath.Join(f.files[3], "operations.json")))
		})
	}
}

func TestSelectedCompensation(t *testing.T) {
	t.Parallel()
	for service, api := range map[string]string{"json_keys": "agora-json-keys-grpc", "authentication": "agora-authentication-rest"} {
		for _, database := range []bool{false, true} {
			name := "unchanged-database"
			if database {
				name = "changed-database"
			}
			t.Run(service+"/"+name, func(t *testing.T) {
				t.Parallel()
				f := compiledFixture(t)
				f.change(service, database)
				f.compile(t)
				writeJSON(t, filepath.Join(f.files[3], "database-mutated-"+service), true)
				rollback := filepath.Join(f.files[3], "rollback.tfvars.json")
				tfvars := readJSON(t, rollback)
				revision := nested(tfvars, "application_release", service)["active_revision"].(string)
				traffic := object{"status": object{"traffic": []any{object{"revisionName": revision, "percent": 100}}}}
				calls := []invocation{
					{Name: "gcloud", Args: []string{"run", "services", "update-traffic", api, "--project=agora-production-test", "--region=europe-west1", "--to-revisions=" + revision + "=100", "--quiet"}},
					{Name: "gcloud", Args: []string{"run", "services", "describe", api, "--project=agora-production-test", "--region=europe-west1", "--format=json"}, Output: jsonText(t, traffic)},
					{Name: "create-reviewed-plan.sh", Args: []string{"release", "fixture-state", f.identity.Commit, "124-13", rollback}},
					{Name: "apply-reviewed-plan.sh", Args: []string{"release", "fixture-state", f.identity.Commit, "124-13", rollback}},
					{Name: "config-custody.sh", Args: []string{"publish", "fixture-state", "release", rollback, "124", "13"}},
				}
				if database {
					calls = append(calls, invocation{Name: "restore-database-release.sh", Args: []string{
						"agora-production-test", "europe-west1-c", strings.ReplaceAll(service, "_", "-"),
						nested(f.config, "database_hosts", service)["data_disk_id"].(string),
						filepath.Join(f.files[3], "previous-database.json"),
					}})
				}
				receiptPath := filepath.Join(f.files[3], "rollback-receipt.json")
				calls = append(calls,
					invocation{Name: "infra", Args: []string{"receipt", "build", "rollback", filepath.Join(f.files[3], "rollback-release.json"), rollback, filepath.Join(f.files[3], "rollback-operations.json"), receiptPath}},
					invocation{Name: "receipt-custody.sh", Args: []string{"publish", "fixture-receipts", receiptPath, "124", "1"}},
				)
				f.driver(t, "rollback", calls)
				receipt := readJSON(t, receiptPath)
				require.Equal(t, f.receipt["database"], receipt["database"])
				require.Equal(t, f.receipt["imageManifest"], receipt["imageManifest"])
				require.Equal(t, tfvars, receipt["activeTfvars"])
				require.Equal(t, f.receipt["database"], readJSON(t, filepath.Join(f.files[3], "previous-database.json")))
				retry := filepath.Join(f.dir, "retry")
				require.NoError(t, f.compiler.CompileRelease([]string{f.files[0], f.files[1], receiptPath, retry}, release.Identity{Commit: f.identity.Commit, RunID: "125", RunAttempt: 1, Nonce: "retry"}, "deploy", "", ""))
				require.Equal(t, []any{service}, readJSON(t, filepath.Join(retry, "release.json"))["services"])
			})
		}
	}
}

func TestRebuildCompensation(t *testing.T) {
	t.Parallel()
	for _, mutated := range [][]string{{}, {"json_keys"}, {"authentication"}, {"authentication", "json_keys"}} {
		t.Run("mutated="+strings.Join(mutated, ","), func(t *testing.T) {
			t.Parallel()
			f := compiledFixture(t)
			delete(nested(f.receipt, "database"), "hosts")
			delete(nested(f.receipt, "activeTfvars"), "database_hosts")
			nested(f.receipt, "activeTfvars")["database_private_ip"] = "10.20.0.99"
			compiled := f.compile(t)
			require.Equal(t, "database-rebuild", compiled["mode"])
			calls := []invocation{}
			for _, value := range compiled["services"].([]any) {
				service := value.(string)
				if !slices.Contains(mutated, service) {
					continue
				}
				writeJSON(t, filepath.Join(f.files[3], "database-mutated-"+service), true)
				calls = append(calls, invocation{Name: "restore-database-release.sh", Args: []string{
					"agora-production-test", "europe-west1-c", strings.ReplaceAll(service, "_", "-"),
					nested(f.config, "database_hosts", service)["data_disk_id"].(string),
					filepath.Join(f.files[3], "empty-database.json"),
				}})
			}
			f.driver(t, "rollback", calls)
			require.JSONEq(t, "null", read(t, filepath.Join(f.files[3], "empty-database.json")))
			require.NoFileExists(t, filepath.Join(f.files[3], "rollback-receipt.json"))
		})
	}
}
