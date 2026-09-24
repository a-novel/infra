package tests_test

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
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
	live, fault               string
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
		args: []string{"operation", "inspect", bucket, project}, live: "42",
		env: map[string]string{
			"MANAGEMENT_PROJECT_ID": "agora-management-test",
			"FOUNDATION_CONFIG":     `{"management_project_id":"agora-management-test","workload_project_id":"agora-production-test","region":"europe-west1","service_projects":{"json-keys":"agora-json-keys-test"}}`,
		},
		records: map[string]object{"intent": intent, "operation": operation, "completion": completion, "guard": guardRef, "configuration": configRef},
		guard:   "/b/" + bucket + "/o/" + guard, config: "/b/" + bucket + "/o/" + config,
		completion: "/b/agora-management-test-123-deployment-receipts/o/services/" + project + "/production/operations/42.json",
	}
}

// Three fixed objects exercise the real SDK. No cloud command or write is permitted.
func (fixture *operationInspection) check(t *testing.T, expected int, want string) {
	t.Helper()
	guard, err := json.Marshal(fixture.records["intent"])
	require.NoError(t, err)
	if _, changed := fixture.records["guard"]["sha256"]; !changed {
		fixture.records["guard"]["sha256"] = fmt.Sprintf("%x", sha256.Sum256(guard))
	}
	completion, err := json.Marshal(fixture.records["completion"])
	require.NoError(t, err)
	var requests, liveReads atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
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
		func(context.Context, io.Writer, string, ...string) error {
			t.Error("inspection must not run a subprocess")
			return nil
		},
		&stdout, &stderr, option.WithEndpoint(server.URL), option.WithoutAuthentication())
	expectCode(t, expected, code, stdout.String()+stderr.String())
	if expected == 0 {
		require.Contains(t, stdout.String(), want)
	} else {
		require.Empty(t, stdout.String(), "no partial evidence report on failure")
	}
	if expected == 64 || expected == 65 {
		require.Zero(t, requests.Load(), "invalid scope must fail before cloud access")
	}
}
