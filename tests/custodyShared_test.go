package tests_test

import (
	"crypto/sha256"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

const sharedRegistration = `{"management_project_id":"agora-management-test","workload_project_id":"agora-private-test",
"public_api_project_id":"agora-api-test","region":"europe-west1","shared_vpc_enabled":true,
"service_release_zones":{"json-keys":["private","public-api"],"authentication":["public-api"]}}`

func TestCustodySharedFoundation(t *testing.T) {
	t.Parallel()
	for _, zone := range []string{"private", "public-api"} {
		for _, fault := range []string{"", "busy", "guard-denied", "guard-ack", "invalid-ack", "config-denied", "config-ack", "completion-denied", "completion-ack", "successor", "delete-ack", "apply", "converge"} {
			t.Run(zone+"/"+fault, func(t *testing.T) {
				t.Parallel()
				project := "agora-private-test"
				if zone == "public-api" {
					project = "agora-api-test"
				}
				scope := "workloads/production/" + zone + "/" + project + "/json-keys"
				f, args, metadataFile := planFixture(t, "service-foundation", scope)
				config := readJSON(t, args[5])
				config["zone"], config["project_id"] = zone, project
				writeJSON(t, args[5], config)
				metadata := readJSON(t, metadataFile)
				metadata["inputsSha256"] = fmt.Sprintf("%x", sha256.Sum256([]byte(read(t, args[5]))))
				writeJSON(t, metadataFile, metadata)
				f.env["FOUNDATION_CONFIG"], f.env["MANAGEMENT_PROJECT_ID"] = sharedRegistration, "agora-management-test"
				f.env["SERVICE_FOUNDATIONS_ENABLED"], f.env["GITHUB_REPOSITORY"] = "true", "a-novel/infra"
				f.env["GITHUB_SHA"], f.env["GITHUB_RUN_ID"], f.env["GITHUB_RUN_ATTEMPT"] = args[2], "124", "1"
				f.fake(t, "tofu", "fake-tofu.sh")
				stub, err := exec.LookPath("true")
				require.NoError(t, err)
				f.link(t, "git", stub)
				f.env["FAKE_TOFU_CALLS"] = filepath.Join(f.dir, "tofu-calls")
				f.env["FAKE_TOFU_PLAN_JSON"], f.env["FAKE_TOFU_PLAN_CODE"] = filepath.Join(f.root, "tests/fixtures/plans/safe.json"), "0"
				f.env["FAKE_TOFU_REQUIRE_ABSENT"] = filepath.Join(filepath.Dir(metadataFile), "plan.tfplan")
				code := 70
				switch fault {
				case "":
					code = 0
				case "apply":
					f.env["FAKE_TOFU_FAIL_ACTION"], code = "apply", 1
				case "converge":
					f.env["FAKE_TOFU_FAIL_ACTION"], code = "plan", 1
				}
				applyStorage(t, f, fault)
				f.custody(t, code, "plan", "apply", args[0], args[1], args[2], args[3], args[5])
				guard := filepath.Join(f.env["FAKE_GCS_ROOT"], args[0], "foundation/operations/production/json-keys/operation.json")
				if fault == "" || fault == "delete-ack" || fault == "guard-denied" {
					require.NoFileExists(t, guard)
				} else {
					require.FileExists(t, guard, "uncertainty must retain admission across both zones")
				}
				if fault == "busy" || fault == "guard-denied" || fault == "guard-ack" || fault == "invalid-ack" {
					require.FileExists(t, f.env["FAKE_TOFU_REQUIRE_ABSENT"])
					require.NotContains(t, read(t, f.env["FAKE_TOFU_CALLS"]), " apply ")
					return
				}
				require.NoFileExists(t, f.env["FAKE_TOFU_REQUIRE_ABSENT"])
				if fault == "" {
					configObject := filepath.Join(f.env["FAKE_GCS_ROOT"], args[0], "foundation", scope, "config/00000000000000000124-00001.tfvars.json")
					require.Equal(t, read(t, args[5]), read(t, configObject))
					receipt := readJSON(t, filepath.Join(f.env["FAKE_GCS_ROOT"], strings.TrimSuffix(args[0], "-tofu-state")+"-deployment-receipts", scope, "production/operations/42.json"))
					require.InDelta(t, 2, nested(receipt, "operation")["schemaVersion"], 0)
					require.Equal(t, scope, nested(receipt, "operation")["scope"])
					output := filepath.Join(f.dir, "fetched.json")
					f.custody(t, 0, "config", "fetch", args[0], "service-foundation", output)
					require.Equal(t, read(t, args[5]), read(t, output))
				}
			})
		}
	}
}

func TestCustodySharedOperationInspection(t *testing.T) {
	t.Parallel()
	for _, zone := range []string{"private", "public-api"} {
		for _, testCase := range []struct {
			name, field string
			value       any
			fault       string
			code        int
		}{
			{name: "Completed"},
			{name: "Incomplete", fault: "missing-completion"},
			{name: "SchemaDowngrade", field: "schemaVersion", value: 1, code: 70},
			{name: "PeerProject", field: "project_id", value: "agora-peer-test", code: 70},
			{name: "PeerService", field: "service", value: "authentication", code: 70},
			{name: "PeerScope", field: "scope", value: "workloads/production/public-api/agora-api-test/authentication", code: 70},
			{name: "WrongScopeProject", field: "scope", value: "workloads/production/private/agora-peer-test/json-keys", code: 70},
			{name: "RuntimeRoot", field: "root", value: "service-release", code: 70},
			{name: "WrongSource", field: "source_project", value: "agora-private-test", code: 70},
			{name: "NativeOperation", field: "kind", value: "native-release", code: 70},
			{name: "Denied", fault: "denied-completion", code: 70},
			{name: "ChangedGuard", fault: "changed-guard", code: 70},
		} {
			t.Run(zone+"/"+testCase.name, func(t *testing.T) {
				t.Parallel()
				f := newSharedOperationInspection(t, zone)
				f.fault = testCase.fault
				if testCase.field != "" {
					f.records["intent"][testCase.field] = testCase.value
				}
				f.check(t, testCase.code, "")
				f.finish()
				code := testCase.code
				if testCase.name == "Incomplete" {
					code = 70
				}
				if code == 0 {
					f.deletes = 1
				}
				f.check(t, code, "")
			})
		}
	}
}

func newSharedOperationInspection(t *testing.T, zone string) *operationInspection {
	t.Helper()
	f := newOperationInspection(t, "service-foundation")
	project := "agora-private-test"
	if zone == "public-api" {
		project = "agora-api-test"
	}
	scope := "workloads/production/" + zone + "/" + project + "/json-keys"
	f.env["FOUNDATION_CONFIG"] = sharedRegistration
	f.args[3] = "workloads/production/json-keys"
	for _, record := range []string{"intent", "operation"} {
		f.records[record]["schemaVersion"], f.records[record]["scope"], f.records[record]["project_id"] = 2, scope, project
	}
	guard := "foundation/operations/production/json-keys/operation.json"
	config := "foundation/" + scope + "/config/00000000000000000124-00001.tfvars.json"
	f.records["guard"]["object"], f.records["configuration"]["object"] = guard, config
	f.guard, f.config = "/b/"+f.args[2]+"/o/"+guard, "/b/"+f.args[2]+"/o/"+config
	f.completion = "/b/agora-management-test-123-deployment-receipts/o/" + scope + "/production/operations/42.json"
	return f
}

func TestSharedOperationCannotClearSuccessor(t *testing.T) {
	t.Parallel()
	f := newSharedOperationInspection(t, "public-api")
	f.finish()
	f.live = "45"
	f.check(t, 70, "")
}

func TestSharedFoundationPlatformCustodyRejected(t *testing.T) {
	t.Parallel()
	f := setup(t)
	storageFixture(t, f)
	f.env["TOFU_STATE_SUFFIX"] = "workloads/production/public/agora-public-test/json-keys"
	f.custody(t, 65, "config", "fetch", "fixture-bucket", "service-foundation", filepath.Join(f.dir, "config.json"))
	_, err := os.Stat(f.env["FAKE_GCS_ROOT"])
	require.ErrorIs(t, err, os.ErrNotExist)
}
