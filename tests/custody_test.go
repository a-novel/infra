package tests_test

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func storageFixture(t *testing.T, f *sandbox) {
	t.Helper()
	f.fake(t, "gcloud", "fake-gcloud-storage.sh")
	f.command(t, "infra")
	f.env["FAKE_GCS_ROOT"] = filepath.Join(f.dir, "storage")
}

func (f *sandbox) custody(t *testing.T, expected int, args ...string) {
	t.Helper()
	code, out := f.run(t, "infra", append([]string{"custody"}, args...)...)
	expectCode(t, expected, code, out)
}

func TestCustodyDocuments(t *testing.T) {
	t.Parallel()
	for _, kind := range []string{"config", "receipt"} {
		t.Run(kind, func(t *testing.T) {
			t.Parallel()
			f := compiledFixture(t)
			storageFixture(t, f.sandbox)
			input, output := f.files[2], filepath.Join(f.dir, "download.json")
			args, action := []string{kind, "publish", "fixture-bucket"}, "latest"
			if kind == "config" {
				args, action = append(args, "release"), "fetch"
			}
			args = append(args, input, "123", "1")
			f.custody(t, 0, args...)
			nested(f.receipt, "sequence")["runAttempt"] = 2
			writeJSON(t, input, f.receipt)
			args[len(args)-1] = "2"
			f.custody(t, 0, args...)
			fetch := append([]string{kind, action}, args[2:len(args)-3]...)
			fetch = append(fetch, output)
			f.custody(t, 0, fetch...)
			require.Equal(t, read(t, input), read(t, output))
			info, err := os.Stat(output)
			require.NoError(t, err)
			require.Equal(t, os.FileMode(0o600), info.Mode().Perm())
			if kind == "receipt" {
				f.custody(t, 0, "receipt", "fetch", "fixture-bucket", output, "123-2")
				args[len(args)-2], args[len(args)-1] = "122", "1"
				f.custody(t, 70, args...)
			}
		})
	}
}

func TestCustodyInventory(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, object, failure, data string
		code                        int
	}{
		{"Empty", "", "", "", 4},
		{"ListDenied", "", "LIST", "", 70},
		{"UnexpectedName", "other.json", "", `{}`, 70},
		{"NestedName", "nested/00000000000000000123-00001.tfvars.json", "", `{}`, 70},
		{"ReadDenied", "00000000000000000123-00001.tfvars.json", "READ", `{}`, 70},
		{"InvalidDocument", "00000000000000000123-00001.tfvars.json", "", `null`, 65},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			f := setup(t)
			storageFixture(t, f)
			if testCase.object != "" {
				remote := filepath.Join(f.env["FAKE_GCS_ROOT"], "fixture-bucket/release/config", testCase.object)
				require.NoError(t, os.MkdirAll(filepath.Dir(remote), 0o700))
				require.NoError(t, os.WriteFile(remote, []byte(testCase.data), 0o600))
			}
			f.env["FAKE_GCS_"+testCase.failure+"_FAILURE"] = "true"
			output := filepath.Join(f.dir, "output.json")
			f.custody(t, testCase.code, "config", "fetch", "fixture-bucket", "release", output)
			require.NoFileExists(t, output)
		})
	}
}

func TestCustodyReceiptRetry(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name   string
		change func(object)
		code   int
	}{
		{"Identical", nil, 0},
		{"Conflicting", func(value object) { value["kind"] = "rollback" }, 70},
		{"WrongRun", func(value object) { nested(value, "sequence")["runId"] = "124" }, 65},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			f := compiledFixture(t)
			storageFixture(t, f.sandbox)
			f.env["FAKE_GCS_LOST_UPLOAD_RESPONSE"] = "true"
			f.custody(t, 0, "receipt", "publish", "fixture-bucket", f.files[2], "123", "1")
			original := read(t, f.files[2])
			if testCase.change != nil {
				testCase.change(f.receipt)
				writeJSON(t, f.files[2], f.receipt)
			}
			f.custody(t, testCase.code, "receipt", "publish", "fixture-bucket", f.files[2], "123", "1")
			f.custody(t, 0, "receipt", "latest", "fixture-bucket", f.files[2])
			require.Equal(t, original, read(t, f.files[2]))
		})
	}
}

func planFixture(t *testing.T) (*sandbox, []string, string) {
	t.Helper()
	f := setup(t)
	storageFixture(t, f)
	f.env["TOFU_STATE_SUFFIX"] = "recovery/agora-recovery-test"
	plan := filepath.Join(f.dir, "reviewed.tfplan")
	require.NoError(t, os.WriteFile(plan, []byte(privateValue+"\x00\xff"), 0o600))
	args := []string{"fixture-bucket", "foundation", strings.Repeat("a", 40), "123-1", plan}
	f.custody(t, 0, append(append([]string{"plan", "publish"}, args...), "false")...)
	remote := filepath.Join(f.env["FAKE_GCS_ROOT"], args[0], args[1], "plans", f.env["TOFU_STATE_SUFFIX"], args[2], args[3])
	return f, args, remote
}

func TestCustodyPlanIntegrity(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name   string
		change func(object)
		tamper bool
	}{
		{"WrongCommit", func(meta object) { meta["commit"] = strings.Repeat("b", 40) }, false},
		{"WrongNamespace", func(meta object) { meta["stateSuffix"] = "" }, false},
		{"Expired", func(meta object) {
			meta["createdEpoch"] = time.Now().Unix() - 90000
			meta["expiresEpoch"] = time.Now().Unix() - 3600
		}, false},
		{"Future", func(meta object) {
			meta["createdEpoch"] = time.Now().Unix() + 600
			meta["expiresEpoch"] = time.Now().Unix() + 87000
		}, false},
		{"UnknownField", func(meta object) { meta["extra"] = true }, false},
		{"MissingApproval", func(meta object) { delete(meta, "destructive") }, false},
		{"HashMismatch", func(object) {}, true},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			f, args, remote := planFixture(t)
			meta := readJSON(t, filepath.Join(remote, "metadata.json"))
			testCase.change(meta)
			writeJSON(t, filepath.Join(remote, "metadata.json"), meta)
			if testCase.tamper {
				writeJSON(t, filepath.Join(remote, "plan.tfplan"), privateValue)
			}
			args[4] = filepath.Join(f.dir, "download.tfplan")
			f.custody(t, 77, append([]string{"plan", "fetch"}, args...)...)
			require.NoFileExists(t, args[4])
			require.NoFileExists(t, args[4]+".destructive")
		})
	}
}

func TestCustodyPlanApply(t *testing.T) {
	t.Parallel()
	for _, failed := range []bool{false, true} {
		name := "Success"
		if failed {
			name = "Error/Apply"
		}
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			f, args, remote := planFixture(t)
			f.custody(t, 70, append(append([]string{"plan", "publish"}, args...), "false")...)
			f.env["TOFU_STATE_SUFFIX"] = "recovery/another-project"
			f.custody(t, 66, append([]string{"plan", "fetch"}, args...)...)
			f.env["TOFU_STATE_SUFFIX"] = "recovery/agora-recovery-test"
			f.custody(t, 0, append([]string{"plan", "fetch"}, args...)...)
			require.Equal(t, privateValue+"\x00\xff", read(t, args[4]))
			require.Equal(t, "false\n", read(t, args[4]+".destructive"))
			for _, file := range []string{args[4], args[4] + ".destructive"} {
				info, err := os.Stat(file)
				require.NoError(t, err)
				require.Equal(t, os.FileMode(0o600), info.Mode().Perm())
			}
			f.fake(t, "tofu", "fake-tofu.sh")
			require.NoError(t, os.WriteFile(filepath.Join(f.bin, "git"), []byte("#!/bin/bash\nexit 0\n"), 0o700))
			for _, command := range []string{"date", "basename", "cut", "sha256sum"} {
				path, err := exec.LookPath(command)
				require.NoError(t, err)
				f.link(t, command, path)
			}
			f.env["FAKE_TOFU_REQUIRE_ABSENT"] = filepath.Join(remote, "plan.tfplan")
			f.env["FAKE_TOFU_PLAN_JSON"], f.env["FAKE_TOFU_PLAN_CODE"] = filepath.Join(f.root, "tests/fixtures/plans/safe.json"), "0"
			expected := 0
			if failed {
				f.env["FAKE_TOFU_FAIL_ACTION"], expected = "apply", 1
			}
			config := filepath.Join(f.dir, "config.json")
			writeJSON(t, config, object{})
			code, out := f.script(t, "apply-reviewed-plan", args[1], args[0], args[2], args[3], config)
			expectCode(t, expected, code, out)
			require.NotContains(t, out, "fixture-sensitive-diagnostic")
			require.NoFileExists(t, filepath.Join(remote, "plan.tfplan"))
			f.custody(t, 66, append([]string{"plan", "fetch"}, args...)...)
		})
	}
}
