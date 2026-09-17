package tests_test

import (
	_ "embed"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

//go:embed testdata/candidate.yaml
var candidateFixture []byte

func driverFixture(t *testing.T) *sandbox {
	t.Helper()
	f := setup(t)
	for name, value := range fixtureYAML[map[string]object](t, candidateFixture) {
		writeJSON(t, filepath.Join(f.dir, name+".json"), value)
	}
	require.NoError(t, os.WriteFile(filepath.Join(f.dir, "driver.sh"), []byte(read(t, filepath.Join(f.root, "ops/google-release-driver.sh"))), 0o600))
	f.env["RELEASE_DIRECTORY"], f.env["STATE_BUCKET"], f.env["RECEIPT_BUCKET"] = f.dir, "fixture-state", "fixture-receipts"
	f.env["GITHUB_SHA"], f.env["GITHUB_RUN_ID"], f.env["GITHUB_RUN_ATTEMPT"] = strings.Repeat("a", 40), "123", "1"
	return f
}

func (f *sandbox) command(t *testing.T, name string) {
	t.Helper()
	binary, err := os.Executable()
	require.NoError(t, err)
	target := filepath.Join(f.bin, name)
	if strings.HasSuffix(name, ".sh") {
		target = filepath.Join(f.dir, name)
	}
	require.NoError(t, os.Symlink(binary, target))
	f.env["INFRA_TEST_COMMAND"] = "1"
}

func TestCandidatePlan(t *testing.T) {
	t.Parallel()
	for index, failure := range []string{"active", "rollback", "candidate", ""} {
		name := "Error/" + failure
		if failure == "" {
			name = "Success"
		}
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			f := driverFixture(t)
			for _, name := range []string{"tofu-gate.sh", "create-reviewed-plan.sh", "apply-reviewed-plan.sh"} {
				f.command(t, name)
			}
			f.env["FAIL_PHASE"] = failure
			code, out := f.run(t, "bash", filepath.Join(f.dir, "driver.sh"), "plan")
			expected := []string{"tofu-gate.sh:active", "tofu-gate.sh:rollback", "create-reviewed-plan.sh:candidate"}
			if failure != "" {
				expectCode(t, 65, code, out)
				expected = expected[:index+1]
			} else {
				expectCode(t, 0, code, out)
			}
			require.Equal(t, strings.Join(expected, "\n")+"\n", read(t, filepath.Join(f.dir, "calls")))
			if failure == "" {
				code, out = f.run(t, "bash", filepath.Join(f.dir, "driver.sh"), "candidate")
				expectCode(t, 0, code, out)
				require.Equal(t, strings.Join(append(expected, "apply-reviewed-plan.sh:candidate"), "\n")+"\n", read(t, filepath.Join(f.dir, "calls")))
			}
		})
	}
}

func TestCandidateSmoke(t *testing.T) {
	t.Parallel()
	for _, failure := range []string{"", "unhealthy", "revision", "target", "audience", "image", "identity", "not-ready"} {
		name := "Error/" + failure
		if failure == "" {
			name = "Success"
		}
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			f := driverFixture(t)
			f.command(t, "gcloud")
			f.env["FAILURE"] = failure
			responses := fixtureYAML[map[string]object](t, candidateFixture)
			job := nested(responses["jobs"], "spec", "template", "spec", "template", "spec")
			container := job["containers"].([]any)[0].(object)
			switch failure {
			case "revision":
				nested(responses["services"], "status")["traffic"].([]any)[0].(object)["revisionName"] = "old"
			case "identity":
				job["serviceAccountName"] = "agora-authentication@fixture-project.iam.gserviceaccount.com"
			case "image":
				container["image"] = "wrong"
			case "target", "audience":
				env := container["env"].([]any)
				if failure == "target" {
					env[1].(object)["value"] = env[0].(object)["value"]
				} else {
					env[0].(object)["value"] = env[1].(object)["value"]
				}
			case "not-ready":
				nested(responses["revisions"], "status")["conditions"].([]any)[0].(object)["status"] = "False"
			}
			for _, name := range []string{"jobs", "services", "revisions"} {
				writeJSON(t, filepath.Join(f.dir, name+".json"), responses[name])
			}
			code, out := f.run(t, "bash", filepath.Join(f.dir, "driver.sh"), "json-smoke")
			operations := readJSON(t, filepath.Join(f.dir, "operations.json"))
			if failure == "" {
				expectCode(t, 0, code, out)
				require.Equal(t, "passed", nested(operations, "health")["jsonKeys"])
				require.Equal(t, "agora-json-keys-smoke-abcde", nested(operations, "executions")["jsonKeysSmoke"])
			} else {
				expectCode(t, 70, code, out)
				require.Equal(t, "not-run", nested(operations, "health")["jsonKeys"])
				require.Empty(t, nested(operations, "executions"))
			}
			if failure == "" || failure == "unhealthy" {
				require.Equal(t, "probe\n", read(t, filepath.Join(f.dir, "calls")))
			} else {
				require.NoFileExists(t, filepath.Join(f.dir, "calls"))
			}
		})
	}
}

func TestCandidateProbe(t *testing.T) {
	t.Parallel()
	for _, status := range []int{0, 1, 14} {
		t.Run(strconv.Itoa(status), func(t *testing.T) {
			t.Parallel()
			f := setup(t)
			f.command(t, "wget")
			f.command(t, "grpcurl")
			f.env["JSON_KEYS_AUDIENCE"], f.env["JSON_KEYS_CANDIDATE"] = "https://fixture.run.app", "https://candidate---fixture.run.app"
			f.env["RPC_CODE"] = strconv.Itoa(status)
			code, out := f.run(t, "sh", filepath.Join(f.root, "environments/production/release/scripts/json-keys-smoke.sh"))
			expectCode(t, status, code, out)
			require.Equal(t, status == 0, strings.Contains(out, "health passed"))
		})
	}
}
