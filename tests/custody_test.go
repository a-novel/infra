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

func planFixture(t *testing.T, root, suffix string) (*sandbox, []string, string) {
	t.Helper()
	f := setup(t)
	storageFixture(t, f)
	f.env["TOFU_STATE_SUFFIX"] = suffix
	plan := filepath.Join(f.dir, "reviewed.tfplan")
	require.NoError(t, os.WriteFile(plan, []byte(privateValue+"\x00\xff"), 0o600))
	args := []string{"agora-management-test-123-tofu-state", root, strings.Repeat("a", 40), "123-1", plan}
	remote := filepath.Join(f.env["FAKE_GCS_ROOT"], args[0], "foundation", "plans", suffix, args[2], args[3])
	meta := filepath.Join(remote, "metadata.json")
	publish := append(append([]string{"plan", "publish"}, args...), "false")
	if root == "service-release" {
		config := filepath.Join(f.dir, "inputs.json")
		writeJSON(t, config, object{"project_id": "agora-json-keys-test", "private": privateValue})
		args, publish = append(args, config), append(publish, config)
		meta = filepath.Join(f.env["FAKE_GCS_ROOT"], args[0], suffix, "release/plans", args[2], args[3], "plan.metadata.json")
	}
	f.custody(t, 0, publish...)
	return f, args, meta
}

func TestCustodyPlanIntegrity(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name   string
		change func(object)
		tamper bool
	}{
		{"WrongCommit", func(meta object) { meta["commit"] = strings.Repeat("b", 40) }, false},
		{"WrongRoot", func(meta object) { meta["root"] = "bootstrap" }, false},
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
		for _, root := range []string{"service-foundation", "service-release"} {
			t.Run(root+"/"+testCase.name, func(t *testing.T) {
				t.Parallel()
				f, args, metadataFile := planFixture(t, root, "services/agora-json-keys-test")
				meta := readJSON(t, metadataFile)
				testCase.change(meta)
				writeJSON(t, metadataFile, meta)
				if testCase.tamper {
					writeJSON(t, filepath.Join(filepath.Dir(metadataFile), "plan.tfplan"), privateValue)
				}
				args[4] = filepath.Join(f.dir, "download.tfplan")
				f.custody(t, 77, append([]string{"plan", "fetch"}, args...)...)
				require.NoFileExists(t, args[4])
				require.NoFileExists(t, args[4]+".destructive")
			})
		}
	}
}

func TestCustodyPlanApply(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, root, suffix string
		failed             bool
	}{
		{"Recovery", "foundation", "recovery/agora-recovery-test", false},
		{"RecoveryFailure", "foundation", "recovery/agora-recovery-test", true},
		{"Service", "service-foundation", "services/agora-json-keys-test", false},
		{"ServiceFailure", "service-foundation", "services/agora-json-keys-test", true},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			f, args, metadataFile := planFixture(t, testCase.root, testCase.suffix)
			remote := filepath.Dir(metadataFile)
			f.custody(t, 70, append(append([]string{"plan", "publish"}, args...), "false")...)
			f.env["TOFU_STATE_SUFFIX"] = strings.Replace(testCase.suffix, "agora-", "peer-", 1)
			f.custody(t, 66, append([]string{"plan", "fetch"}, args...)...)
			f.env["TOFU_STATE_SUFFIX"] = testCase.suffix
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
			if testCase.failed {
				f.env["FAKE_TOFU_FAIL_ACTION"], expected = "apply", 1
			}
			config := filepath.Join(f.dir, "config.json")
			writeJSON(t, config, object{})
			if testCase.root == "service-foundation" {
				f.env["MANAGEMENT_PROJECT_ID"] = "agora-management-test"
				f.env["FOUNDATION_CONFIG"] = `{"management_project_id":"agora-management-test","workload_project_id":"agora-production-test","region":"europe-west1","service_projects":{"json-keys":"agora-json-keys-test"}}`
				writeJSON(t, config, object{
					"project_id": "agora-json-keys-test", "management_project_id": "agora-management-test",
					"region": "europe-west1", "state_bucket": args[0], "service": "json-keys",
				})
			}
			code, out := f.script(t, "apply-reviewed-plan", args[1], args[0], args[2], args[3], config)
			expectCode(t, expected, code, out)
			require.NotContains(t, out, "fixture-sensitive-diagnostic")
			require.NoFileExists(t, filepath.Join(remote, "plan.tfplan"))
			f.custody(t, 66, append([]string{"plan", "fetch"}, args...)...)
		})
	}
}

func TestCustodyServiceScope(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, root, suffix string
		code               int
	}{
		{"Exact", "service-foundation", "services/agora-json-keys-test", 0},
		{"Peer", "service-foundation", "services/agora-authentication-test", 66},
		{"MissingScope", "service-foundation", "", 65},
		{"Recovery", "service-foundation", "recovery/agora-json-keys-test", 65},
		{"Legacy", "foundation", "services/agora-json-keys-test", 65},
		{"Traversal", "service-foundation", "services/../foundation", 65},
		{"ReleaseNeedsInputs", "service-release", "services/agora-json-keys-test", 64},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			f, args, _ := planFixture(t, "service-foundation", "services/agora-json-keys-test")
			args[1], f.env["TOFU_STATE_SUFFIX"] = testCase.root, testCase.suffix
			f.custody(t, testCase.code, append([]string{"plan", "fetch"}, args...)...)
		})
	}
	for _, root := range []string{"service-foundation", "service-release"} {
		t.Run("Configuration/"+root, func(t *testing.T) {
			t.Parallel()
			f := setup(t)
			storageFixture(t, f)
			f.env["TOFU_STATE_SUFFIX"] = "services/agora-json-keys-test"
			input, output := filepath.Join(f.dir, "config.json"), filepath.Join(f.dir, "download.json")
			writeJSON(t, input, object{"project_id": "agora-json-keys-test"})
			code := 0
			if root == "service-release" {
				code = 65
				writeJSON(t, filepath.Join(f.env["FAKE_GCS_ROOT"], "fixture-bucket/services/agora-json-keys-test/release/config/00000000000000000123-00001.tfvars.json"), readJSON(t, input))
			}
			f.custody(t, code, "config", "publish", "fixture-bucket", root, input, "123", "1")
			f.custody(t, 0, "config", "fetch", "fixture-bucket", root, output)
			require.Equal(t, read(t, input), read(t, output))
			f.env["TOFU_STATE_SUFFIX"] = "services/agora-authentication-test"
			f.custody(t, 4, "config", "fetch", "fixture-bucket", root, output)
			f.custody(t, 4, "config", "fetch", "fixture-bucket", "foundation", output)
			f.env["TOFU_STATE_SUFFIX"] = "services/../foundation"
			f.custody(t, 65, "config", "fetch", "fixture-bucket", root, output)
		})
	}
}

func TestCustodyServicePlan(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name string
		code int
	}{
		{"Exact", 0},
		{"ChangedInputs", 77},
		{"MissingInputBinding", 77},
		{"UnreadableInputs", 64},
		{"InvalidInputs", 64},
		{"MissingInputsArgument", 64},
		{"PeerScope", 66},
		{"WrongAttempt", 66},
		{"ReadDenied", 66},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			f, args, metadataFile := planFixture(t, "service-release", "services/agora-json-keys-test")
			f.env["FAKE_GCS_CALLS"] = filepath.Join(f.dir, "storage-calls")
			args[4] = filepath.Join(f.dir, "download.tfplan")
			switch testCase.name {
			case "ChangedInputs":
				writeJSON(t, args[5], object{"project_id": "agora-json-keys-test", "private": privateValue, "changed": true})
			case "MissingInputBinding":
				meta := readJSON(t, metadataFile)
				delete(meta, "inputsSha256")
				writeJSON(t, metadataFile, meta)
			case "UnreadableInputs":
				args[5] = filepath.Join(f.dir, "missing.json")
			case "InvalidInputs":
				writeJSON(t, args[5], nil)
			case "MissingInputsArgument":
				args = args[:5]
			case "PeerScope":
				f.env["TOFU_STATE_SUFFIX"] = "services/agora-authentication-test"
			case "WrongAttempt":
				args[3] = "123-2"
			case "ReadDenied":
				f.env["FAKE_GCS_READ_FAILURE"] = "true"
			}
			f.custody(t, testCase.code, append([]string{"plan", "fetch"}, args...)...)
			if testCase.code != 0 {
				require.NoFileExists(t, args[4])
				if testCase.code == 64 {
					require.NoFileExists(t, f.env["FAKE_GCS_CALLS"])
				} else {
					require.NotContains(t, read(t, f.env["FAKE_GCS_CALLS"]), "/plan.tfplan", "reject before downloading the opaque plan")
				}
				return
			}
			require.Equal(t, privateValue+"\x00\xff", read(t, args[4]))
			f.custody(t, 0, append([]string{"plan", "consume"}, args[:4]...)...)
			f.custody(t, 66, append([]string{"plan", "fetch"}, args...)...)
			require.NoFileExists(t, metadataFile)
			require.NoFileExists(t, filepath.Join(filepath.Dir(metadataFile), "plan.tfplan"))
		})
	}
}

func TestCustodyPlanLostUpload(t *testing.T) {
	t.Parallel()
	f, args, metadataFile := planFixture(t, "service-release", "services/agora-json-keys-test")
	args[3] = "124-1"
	metadataFile = strings.Replace(metadataFile, "/123-1/", "/124-1/", 1)
	f.env["FAKE_GCS_LOST_UPLOAD_RESPONSE"] = "true"
	publish := append(append([]string{"plan", "publish"}, args[:5]...), "false", args[5])
	f.custody(t, 70, publish...)
	require.FileExists(t, filepath.Join(filepath.Dir(metadataFile), "plan.tfplan"))
	require.NoFileExists(t, metadataFile)
	delete(f.env, "FAKE_GCS_LOST_UPLOAD_RESPONSE")
	f.custody(t, 70, publish...)
	args[4] = filepath.Join(f.dir, "download.tfplan")
	f.custody(t, 66, append([]string{"plan", "fetch"}, args...)...)
	require.NoFileExists(t, args[4])
}

func TestServiceBackend(t *testing.T) {
	t.Parallel()
	for _, root := range []string{"service-foundation", "service-release"} {
		for _, testCase := range []struct {
			name, variable, value, action string
			code                          int
		}{
			{name: "NativeBackend"},
			{name: "Drift", action: "drift", code: 2},
			{name: "PeerScope", variable: "TOFU_STATE_SUFFIX", value: "services/agora-peer-test", code: 65},
			{name: "WorkspaceOverride", variable: "TF_WORKSPACE", value: "peer", code: 65},
			{name: "CLIOverride", variable: "TF_CLI_ARGS_init", value: "-backend-config=prefix=peer", code: 65},
			{name: "DisabledPlan", action: "plan", code: 77},
			{name: "DisabledApply", action: "apply", code: 77},
			{name: "DisabledOutput", action: "output", code: 77},
			{name: "DisabledConverge", action: "converge", code: 77},
		} {
			if root == "service-foundation" && testCase.code == 77 {
				continue
			}
			t.Run(root+"/"+testCase.name, func(t *testing.T) {
				t.Parallel()
				f := setup(t)
				f.command(t, "infra")
				f.fake(t, "tofu", "fake-tofu.sh")
				stub, err := exec.LookPath("true")
				require.NoError(t, err)
				f.link(t, "git", stub)
				bucket := "agora-management-test-123-tofu-state"
				config, calls := filepath.Join(f.dir, "config.json"), filepath.Join(f.dir, "tofu-calls")
				writeJSON(t, config, object{
					"project_id": "agora-json-keys-test", "management_project_id": "agora-management-test",
					"region": "europe-west1", "state_bucket": bucket, "service": "json-keys",
				})
				f.env["FOUNDATION_CONFIG"] = `{"management_project_id":"agora-management-test","workload_project_id":"agora-production-test","region":"europe-west1","service_projects":{"json-keys":"agora-json-keys-test"}}`
				f.env["MANAGEMENT_PROJECT_ID"], f.env["TOFU_STATE_SUFFIX"] = "agora-management-test", "services/agora-json-keys-test"
				f.env["TOFU_VAR_FILE"], f.env["FAKE_TOFU_CALLS"] = config, calls
				f.env["FAKE_TOFU_PLAN_JSON"], f.env["FAKE_TOFU_PLAN_CODE"] = filepath.Join(f.root, "tests/fixtures/plans/safe.json"), "2"
				if testCase.variable != "" {
					f.env[testCase.variable] = testCase.value
				}
				action := testCase.action
				if action == "" {
					action = "assess"
				}
				args := []string{action, root, bucket}
				if action == "plan" || action == "apply" || action == "output" {
					args = append(args, filepath.Join(f.dir, "private-file"))
				}
				code, out := f.script(t, "tofu-gate", args...)
				expectCode(t, testCase.code, code, out)
				if testCase.code >= 65 {
					require.NoFileExists(t, calls, "invalid scope must fail before initialization")
					return
				}
				require.Contains(t, read(t, calls), " init -reconfigure -input=false -no-color -lockfile=readonly -var-file="+config+"\n")
				require.NotContains(t, read(t, calls), "-backend-config")
			})
		}
	}
}
