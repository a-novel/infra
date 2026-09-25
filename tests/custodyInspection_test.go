package tests_test

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"google.golang.org/api/option"

	"github.com/a-novel/infra/internal/custody"
)

func TestCustodyOperationInspection(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, root, selected, live, fault, want string
		code                                    int
	}{
		{"HeldFoundation", "service-foundation", "", "42", "", "42 (held)", 0},
		{"HeldJobBootstrap", "service-release", "", "42", "", "recorded convergence", 0},
		{"AcknowledgementLost", "service-release", "42", "", "", "42 (no live guard)", 0},
		{"Successor", "service-release", "42", "45", "", "another generation is live", 0},
		{"NoLiveGuard", "service-release", "", "", "", "does not establish any earlier apply outcome", 0},
		{"Incomplete", "service-release", "", "42", "missing-completion", "apply may still have changed resources", 0},
		{"DeniedGuard", "service-release", "", "42", "denied-guard", "", 70},
		{"DeniedCompletion", "service-release", "", "42", "denied-completion", "", 70},
		{"MissingArchive", "service-release", "42", "", "missing-archive", "", 70},
		{"MissingConfiguration", "service-release", "", "42", "missing-configuration", "", 70},
		{"ChangedConfiguration", "service-release", "", "42", "changed-configuration", "", 70},
		{"ChangedGuard", "service-release", "", "42", "changed-guard", "", 70},
		{"OversizedRecord", "service-release", "", "42", "oversized", "", 70},
		{"MalformedRecord", "service-release", "", "42", "malformed", "", 70},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			fixture := newOperationInspection(t, testCase.root)
			fixture.live, fixture.fault = testCase.live, testCase.fault
			if testCase.selected != "" {
				fixture.args = append(fixture.args, testCase.selected)
			}
			fixture.check(t, testCase.code, testCase.want)
		})
	}
}

func TestCustodyOperationEvidenceBinding(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, record, field string
		value               any
	}{
		{"FutureSchema", "intent", "schemaVersion", 2},
		{"UnknownField", "intent", "unexpected", privateValue},
		{"PeerProject", "intent", "project_id", "agora-peer-test"},
		{"PeerService", "intent", "service", "authentication"},
		{"PeerRegion", "intent", "region", "us-central1"},
		{"UnsafeCommit", "intent", "commit", privateValue + "\n"},
		{"UnsupportedRoot", "intent", "root", "bootstrap"},
		{"InvalidRun", "intent", "runAttempt", "0"},
		{"WrongIntent", "operation", "planId", "987-1"},
		{"WrongOutcome", "completion", "outcome", "pending"},
		{"WrongGuardGeneration", "guard", "generation", "41"},
		{"WrongGuardHash", "guard", "sha256", strings.Repeat("0", 64)},
		{"PeerConfiguration", "configuration", "object", "services/agora-peer-test/release/config/other.json"},
		{"OtherBucket", "configuration", "bucket", "peer-bucket"},
		{"UnpinnedConfiguration", "configuration", "generation", "0"},
		{"WrongConfigurationHash", "configuration", "sha256", strings.Repeat("0", 64)},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			fixture := newOperationInspection(t, "service-release")
			fixture.records[testCase.record][testCase.field] = testCase.value
			fixture.check(t, 70, "")
			fixture.finish()
			fixture.check(t, 70, "")
		})
	}
}

func TestCustodyFinishApply(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, root, live, fault, field, value, want string
		code, deletes                               int
	}{
		{name: "Foundation", root: "service-foundation", live: "42", deletes: 1, want: "No resources reapplied"},
		{name: "Jobs", live: "42", deletes: 1, want: "No resources reapplied"},
		{name: "AlreadyAbsent", want: "No mutation performed"},
		{name: "Successor", live: "45", code: 70},
		{name: "Incomplete", live: "42", fault: "missing-completion", code: 70},
		{name: "ConfigurationChanged", live: "42", fault: "changed-configuration", code: 70},
		{name: "ActiveWriter", live: "42", field: "status", value: "in_progress", code: 70},
		{name: "WrongAttempt", live: "42", field: "run_attempt", value: "2", code: 70},
		{name: "WrongCommit", live: "42", field: "head_sha", value: strings.Repeat("b", 40), code: 70},
		{name: "WrongWorkflow", live: "42", field: "path", value: ".github/workflows/recovery.yaml", code: 70},
		{name: "WrongRepo", live: "42", field: "repository", value: "peer/infra", code: 70},
		{name: "SelectedOtherRoot", live: "42", fault: "selected-root", code: 70},
		{name: "WrongRoot", live: "42", field: "display_title", value: "foundation apply service-foundation/json-keys by @operator", code: 70},
		{name: "WrongService", live: "42", field: "display_title", value: "foundation apply service-release/authentication by @operator", code: 70},
		{name: "UnknownWriter", live: "42", fault: "writer-unavailable", code: 70},
		{name: "DeleteRace", live: "42", fault: "delete-race", deletes: 1, code: 70},
		{name: "DeleteUnconfirmed", live: "42", fault: "delete-unconfirmed", deletes: 1, code: 70},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			root := testCase.root
			if root == "" {
				root = "service-release"
			}
			fixture := newOperationInspection(t, root)
			fixture.finish()
			fixture.live, fixture.fault, fixture.deletes = testCase.live, testCase.fault, testCase.deletes
			if testCase.fault == "selected-root" {
				fixture.args[3] = "service-foundation"
			}
			if testCase.field != "" {
				fixture.writer[testCase.field] = testCase.value
			}
			fixture.check(t, testCase.code, testCase.want)
		})
	}
}

func TestCustodyOperationInspectionScope(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, change string
		code         int
	}{
		{"UnregisteredProject", "project", 65},
		{"OtherBucket", "bucket", 65},
		{"MissingRegistration", "registration", 65},
		{"WrongManagement", "management", 65},
		{"InvalidGeneration", "generation", 64},
		{"UnlockUnavailable", "unlock", 64},
		{"FinishInactive", "finish-inactive", 65},
		{"FinishWrongWorkflow", "finish-workflow", 65},
		{"FinishWrongConfirmation", "finish-confirm", 65},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			fixture := newOperationInspection(t, "service-release")
			switch testCase.change {
			case "project":
				fixture.args[3] = "agora-peer-test"
			case "bucket":
				fixture.args[2] = "peer-bucket"
			case "registration":
				delete(fixture.env, "FOUNDATION_CONFIG")
			case "management":
				fixture.env["MANAGEMENT_PROJECT_ID"] = "agora-other-test"
			case "generation":
				fixture.args = append(fixture.args, "-1")
			case "unlock":
				fixture.args[1] = "unlock"
			case "finish-inactive", "finish-workflow", "finish-confirm":
				fixture.finish()
				switch testCase.change {
				case "finish-inactive":
					delete(fixture.env, "SERVICE_OPERATION_RECOVERY_ENABLED")
				case "finish-workflow":
					delete(fixture.env, "GITHUB_WORKFLOW_REF")
				case "finish-confirm":
					fixture.args[6] = "FINISH authentication 42"
				}
			}
			fixture.check(t, testCase.code, "")
		})
	}
}

type operationInspection struct {
	args                      []string
	env                       map[string]string
	records                   map[string]object
	guard, completion, config string
	root, live, fault         string
	writer                    object
	deletes                   int
}

func (fixture *operationInspection) finish() {
	fixture.args = []string{"operation", "finish", fixture.args[2], fixture.root, "agora-json-keys-test", "42", "FINISH json-keys 42"}
	fixture.env["STATE_BUCKET"] = fixture.args[2]
	fixture.env["SERVICE_OPERATION_RECOVERY_ENABLED"] = "true"
	fixture.env["GITHUB_EVENT_NAME"] = "workflow_dispatch"
	fixture.env["GITHUB_WORKFLOW_REF"] = "a-novel/infra/.github/workflows/foundation.yaml@refs/heads/master"
	fixture.writer = object{
		"id": 124, "run_attempt": 1, "status": "completed", "head_branch": "master", "head_sha": strings.Repeat("a", 40),
		"event": "workflow_dispatch", "path": ".github/workflows/foundation.yaml", "repository": "a-novel/infra",
		"display_title": "foundation apply " + fixture.args[3] + "/json-keys by @operator",
	}
}

func newOperationInspection(t *testing.T, root string) *operationInspection {
	t.Helper()
	bucket, project := "agora-management-test-123-tofu-state", "agora-json-keys-test"
	guard := "services/" + project + "/release/operation.json"
	config := "services/" + project + "/release/config/00000000000000000124-00001.tfvars.json"
	if root == "service-foundation" {
		config = "foundation/services/" + project + "/config/00000000000000000124-00001.tfvars.json"
	}
	intent := object{
		"schemaVersion": 1, "root": root, "project_id": project, "service": "json-keys", "region": "europe-west1",
		"commit": strings.Repeat("a", 40), "runId": "124", "runAttempt": "1", "planId": "123-1",
		"planSha256": strings.Repeat("b", 64), "inputsSha256": fmt.Sprintf("%x", sha256.Sum256([]byte(privateValue))),
	}
	guardRef := object{"bucket": bucket, "object": guard, "generation": "42"}
	configRef := object{"bucket": bucket, "object": config, "generation": "44", "sha256": intent["inputsSha256"]}
	operation := object{}
	for key, value := range intent {
		operation[key] = value
	}
	completion := object{"schemaVersion": 1, "outcome": "converged", "operation": operation, "guard": guardRef, "configuration": configRef}
	return &operationInspection{
		args: []string{"operation", "inspect", bucket, project}, root: root, live: "42",
		env: map[string]string{
			"MANAGEMENT_PROJECT_ID": "agora-management-test",
			"FOUNDATION_CONFIG":     `{"management_project_id":"agora-management-test","workload_project_id":"agora-production-test","region":"europe-west1","service_projects":{"json-keys":"agora-json-keys-test"}}`,
		},
		records: map[string]object{"intent": intent, "operation": operation, "completion": completion, "guard": guardRef, "configuration": configRef},
		guard:   "/b/" + bucket + "/o/" + guard, config: "/b/" + bucket + "/o/" + config,
		completion: "/b/agora-management-test-123-deployment-receipts/o/services/" + project + "/production/operations/42.json",
	}
}

// Three fixed objects exercise the SDK. Finishing permits only a conditional live-guard deletion.
func (fixture *operationInspection) check(t *testing.T, expected int, want string) {
	t.Helper()
	guard, err := json.Marshal(fixture.records["intent"])
	require.NoError(t, err)
	if _, changed := fixture.records["guard"]["sha256"]; !changed {
		fixture.records["guard"]["sha256"] = fmt.Sprintf("%x", sha256.Sum256(guard))
	}
	completion, err := json.Marshal(fixture.records["completion"])
	require.NoError(t, err)
	var requests, liveReads, deletes atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		if r.Method == http.MethodDelete {
			deletes.Add(1)
			assert.Equal(t, fixture.guard, r.URL.Path)
			assert.Equal(t, "42", r.URL.Query().Get("ifGenerationMatch"), "delete only the inspected live guard")
			assert.False(t, r.URL.Query().Has("generation"), "never delete a retained archive")
			switch fixture.fault {
			case "delete-race":
				http.Error(w, privateValue, http.StatusPreconditionFailed)
			case "delete-unconfirmed":
				http.Error(w, privateValue, http.StatusInternalServerError)
			default:
				w.WriteHeader(http.StatusNoContent)
			}
			return
		}
		assert.Equal(t, http.MethodGet, r.Method)
		data, generation, fault := []byte(nil), "", ""
		switch r.URL.Path {
		case fixture.guard:
			data, generation, fault = guard, "42", "guard"
			if r.URL.Query().Get("alt") != "media" {
				count := liveReads.Add(1)
				generation = fixture.live
				if fixture.fault == "changed-guard" && count > 1 {
					generation = "45"
				}
			} else {
				if fixture.fault == "missing-archive" {
					generation = ""
				}
				switch fixture.fault {
				case "oversized":
					data = bytes.Repeat([]byte("x"), (1<<20)+1)
				case "malformed":
					data = append(data, []byte(` {}`)...)
				}
			}
		case fixture.completion:
			data, generation, fault = completion, "43", "completion"
		case fixture.config:
			data, generation, fault = []byte(privateValue), "44", "configuration"
			if fixture.fault == "changed-configuration" {
				data = append(data, '\n')
			}
		default:
			t.Errorf("unexpected object read: %s", r.URL.Path)
		}
		if fixture.fault == "denied-"+fault {
			http.Error(w, privateValue, http.StatusForbidden)
			return
		}
		if generation == "" || fixture.fault == "missing-"+fault {
			http.Error(w, privateValue, http.StatusNotFound)
			return
		}
		if r.URL.Query().Get("alt") == "media" {
			assert.Equal(t, generation, r.URL.Query().Get("generation"), "downloads must select an exact version")
			_, err := w.Write(data)
			assert.NoError(t, err)
			return
		}
		bucket, name, _ := strings.Cut(strings.TrimPrefix(r.URL.Path, "/b/"), "/o/")
		assert.NoError(t, json.NewEncoder(w).Encode(object{"bucket": bucket, "name": name, "generation": generation}))
	}))
	t.Cleanup(server.Close)
	var stdout, stderr bytes.Buffer
	code := custody.Run(t.Context(), fixture.args, func(key string) string { return fixture.env[key] },
		func(_ context.Context, output io.Writer, command string, args ...string) error {
			assert.Equal(t, "finish", fixture.args[1], "inspection must not run a subprocess")
			assert.Equal(t, "gh", command)
			assert.Equal(t, []string{
				"api", "--hostname", "github.com", "repos/a-novel/infra/actions/runs/124/attempts/1", "--jq",
				`{id,run_attempt,status,head_branch,head_sha,event,path,display_title,repository:.repository.full_name}`,
			}, args)
			if fixture.fault == "writer-unavailable" {
				return errors.New(privateValue)
			}
			return json.NewEncoder(output).Encode(fixture.writer)
		},
		&stdout, &stderr, option.WithEndpoint(server.URL), option.WithoutAuthentication())
	expectCode(t, expected, code, stdout.String()+stderr.String())
	require.EqualValues(t, fixture.deletes, deletes.Load())
	if expected == 0 {
		require.Contains(t, stdout.String(), want)
	} else {
		require.Empty(t, stdout.String(), "no partial evidence report on failure")
	}
	if expected == 64 || expected == 65 {
		require.Zero(t, requests.Load(), "invalid scope must fail before cloud access")
	}
}
