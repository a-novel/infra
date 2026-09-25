package submission_test

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

	"cloud.google.com/go/deploy/apiv1/deploypb"
	"github.com/stretchr/testify/require"
	"google.golang.org/api/option"

	"github.com/a-novel/infra/internal/custody"
)

func TestOperationEvidence(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, record, field string
		value               any
		code, finishCode    int
		want                string
	}{
		{name: "Success/Held", want: "42 (held)"},
		{name: "Success/Deleted", want: "42 (no live guard)"},
		{name: "Success/Successor", finishCode: 70, want: "another generation is live"},
		{name: "Success/Incomplete", finishCode: 70, want: "not recorded; native work may"},
		{name: "Error/GuardChanged", code: 70, finishCode: 70},
		{name: "Error/Denied", code: 70, finishCode: 70},
		{name: "Error/MissingReceipt", code: 70, finishCode: 70},
		{name: "Error/Unregistered", code: 65, finishCode: 65},
		{name: "Error/Duplicate", code: 70, finishCode: 70},
		{"Error/GuardHash", "guard", "sha256", strings.Repeat("0", 64), 70, 70, ""},
		{"Error/GuardKind", "guard", "kind", "future-kind", 70, 70, ""},
		{"Error/GuardVersion", "guard", "schemaVersion", 2, 70, 70, ""},
		{"Error/Run", "guard", "runId", "unsafe\nprivate-value", 70, 70, ""},
		{"Error/PeerProject", "config", "project_id", "agora-peer-test", 70, 70, ""},
		{"Error/UnknownConfiguration", "config", "unexpected", "private-value", 70, 70, ""},
		{"Error/PointerScope", "pointer", "bucket", "peer-bucket", 70, 70, ""},
		{"Error/PointerPath", "pointer", "object", "services/agora-peer-test/production/native-success/release-1.json", 70, 70, ""},
		{"Error/PointerGeneration", "pointer", "generation", "0", 70, 70, ""},
		{"Error/RecordGeneration", "receipt", "guardGeneration", "41", 70, 70, ""},
		{"Error/RecordConfiguration", "receipt", "configuration", map[string]any{}, 70, 70, ""},
		{"Error/RecordVersion", "receipt", "schemaVersion", 2, 70, 70, ""},
		{"Error/RecordedAt", "receipt", "completedAt", "private-value", 70, 70, ""},
		{"Error/ReleaseIdentity", "release", "name", "projects/999999/locations/europe-west1/deliveryPipelines/peer/releases/release-1", 70, 70, ""},
		{"Error/ReleaseRender", "release", "renderState", "FAILED", 70, 70, ""},
		{"Error/RolloutIdentity", "rollout", "annotations", map[string]string{}, 70, 70, ""},
		{"Error/RolloutApproval", "rollout", "approvalState", "NEEDS_APPROVAL", 70, 70, ""},
		{"Error/SkippedVerification", "rollout", "phases", []any{}, 70, 70, ""},
		{"Finish/ActiveWriter", "writer", "status", "in_progress", 0, 70, "42 (held)"},
		{"Finish/WrongWorkflow", "writer", "path", ".github/workflows/foundation.yaml", 0, 70, "42 (held)"},
		{"Finish/WrongAction", "writer", "display_title", "production deploy by @operator", 0, 70, "42 (held)"},
		{"Finish/WrongAttempt", "writer", "run_attempt", 2, 0, 70, "42 (held)"},
		{"Finish/WrongCommit", "writer", "head_sha", strings.Repeat("b", 40), 0, 70, "42 (held)"},
		{"Finish/DeleteRace", "delete", "status", 412, 0, 70, "42 (held)"},
		{"Finish/DeleteUnconfirmed", "delete", "status", 500, 0, 70, "42 (held)"},
	} {
		for _, action := range []string{"inspect", "finish"} {
			t.Run(action+"/"+testCase.name, func(t *testing.T) {
				t.Parallel()
				request := fixture(t)
				release := request.Release
				release.Uid, release.RenderState = "release-uid", deploypb.Release_SUCCEEDED
				job, _ := migrationFixture(t, release)
				// Output fields are native evidence, not allowed request inputs.
				config, env := operationFixture(t, fixture(t), job, job)
				decode := func(data []byte) map[string]any {
					var value map[string]any
					if err := json.Unmarshal(data, &value); err != nil {
						panic(err)
					}
					return value
				}
				guard := map[string]any{"schemaVersion": 1, "kind": "native-release", "runId": "123", "runAttempt": "1"}
				prefix := "services/agora-json-keys-test/production/"
				pointer := map[string]any{"schemaVersion": 1, "kind": "native-release", "bucket": bucket, "object": prefix + "native-success/release-1.json", "generation": "44"}
				receipt := map[string]any{"schemaVersion": 1, "kind": "native-release", "guardGeneration": "42", "completedAt": "2026-09-25T12:00:00Z", "configuration": config}
				records := map[string]map[string]any{
					"guard": guard, "config": config, "pointer": pointer, "receipt": receipt,
					"release": decode(wire(t, release)), "rollout": decode(wire(t, operationRollout(t, release))),
					"writer": {
						"id": 123, "run_attempt": 1, "status": "completed", "head_branch": "master", "head_sha": env["GITHUB_SHA"],
						"event": "workflow_dispatch", "path": ".github/workflows/release.yaml", "repository": "a-novel/infra",
						"display_title": "production deploy-service by @operator",
					},
					"delete": {},
				}
				if testCase.record != "" {
					records[testCase.record][testCase.field] = testCase.value
				}
				guard["configuration"] = config
				if testCase.name != "Error/GuardHash" {
					guard["sha256"] = fmt.Sprintf("%x", sha256.Sum256(encodeOperation(t, config)))
				}
				receipt["release"], receipt["rollout"] = records["release"], records["rollout"]
				guardData := encodeOperation(t, guard)
				if testCase.name == "Error/Duplicate" {
					guardData = append([]byte(`{"kind":"rotation",`), guardData[1:]...)
				}
				state := env["STATE_BUCKET"]
				guardPath := "/b/" + state + "/o/services/agora-json-keys-test/release/operation.json"
				type object struct {
					data       []byte
					generation string
				}
				objects := map[string]object{
					guardPath: {guardData, "42"},
					"/b/" + bucket + "/o/" + prefix + "operations/42.json":            {encodeOperation(t, pointer), "43"},
					"/b/" + bucket + "/o/" + prefix + "native-success/release-1.json": {encodeOperation(t, receipt), "44"},
				}
				var calls, liveReads, deletes atomic.Int32
				server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					calls.Add(1)
					if r.Method == http.MethodDelete && action == "finish" && r.URL.Path == guardPath {
						deletes.Add(1)
						if r.URL.Query().Get("ifGenerationMatch") != "42" || r.URL.Query().Has("generation") {
							t.Error("deletion must match the live generation, never an archive")
						}
						status, _ := records["delete"]["status"].(int)
						if status == 0 {
							status = http.StatusNoContent
						}
						w.WriteHeader(status)
						return
					}
					entry, exists := objects[r.URL.Path]
					if !exists || r.Method != http.MethodGet {
						t.Errorf("unexpected request %s %s", r.Method, r.URL.Path)
						w.WriteHeader(403)
						return
					}
					if strings.Contains(r.URL.Path, "/operations/") {
						if testCase.name == "Success/Incomplete" {
							w.WriteHeader(404)
							return
						}
						if testCase.name == "Error/Denied" {
							w.WriteHeader(403)
							return
						}
					}
					if testCase.name == "Error/MissingReceipt" && strings.Contains(r.URL.Path, "/native-success/") {
						w.WriteHeader(404)
						return
					}
					if r.URL.Query().Get("alt") == "media" {
						if r.URL.Query().Get("generation") != entry.generation {
							t.Error("unpinned evidence download")
						}
						_, _ = w.Write(entry.data)
						return
					}
					if r.URL.Path == guardPath {
						count := liveReads.Add(1)
						if testCase.name == "Success/Deleted" {
							w.WriteHeader(404)
							return
						}
						if testCase.name == "Success/Successor" || (testCase.name == "Error/GuardChanged" && count > 1) {
							entry.generation = "45"
						}
					}
					selectedBucket, name, _ := strings.Cut(strings.TrimPrefix(r.URL.Path, "/b/"), "/o/")
					_ = json.NewEncoder(w).Encode(map[string]string{"bucket": selectedBucket, "name": name, "generation": entry.generation})
				}))
				defer server.Close()
				delete(env, "SERVICE_NATIVE_RELEASE_ENABLED")
				env["GITHUB_SHA"] = strings.Repeat("b", 40)
				args := []string{"operation", action, state, "agora-json-keys-test", "42"}
				if testCase.name == "Error/Unregistered" {
					delete(env, "FOUNDATION_CONFIG")
				}
				code, want, wantDeletes := testCase.code, testCase.want, int32(0)
				if action == "finish" {
					args = append(args, "FINISH json-keys 42")
					env["SERVICE_OPERATION_RECOVERY_ENABLED"] = "true"
					env["GITHUB_WORKFLOW_REF"] = "a-novel/infra/.github/workflows/foundation.yaml@refs/heads/master"
					code, want = testCase.finishCode, "No deployment work repeated"
					if code == 0 || testCase.record == "delete" {
						wantDeletes = 1
					}
					if testCase.name == "Success/Deleted" {
						want, wantDeletes = "No mutation performed", 0
					}
				}
				var output, diagnostic bytes.Buffer
				got := custody.Run(t.Context(), args, func(key string) string { return env[key] },
					func(_ context.Context, output io.Writer, command string, args ...string) error {
						require.Equal(t, "finish", action, "inspection cannot run a command")
						require.Equal(t, "gh", command)
						require.Equal(t, []string{
							"api", "--hostname", "github.com", "repos/a-novel/infra/actions/runs/123/attempts/1", "--jq",
							`{id,run_attempt,status,head_branch,head_sha,event,path,display_title,repository:.repository.full_name}`,
						}, args)
						return json.NewEncoder(output).Encode(records["writer"])
					},
					&output, &diagnostic, option.WithEndpoint(server.URL), option.WithoutAuthentication())
				require.Equal(t, code, got, "%s", &diagnostic)
				require.Equal(t, wantDeletes, deletes.Load())
				if code == 0 {
					require.Contains(t, output.String(), want)
				} else {
					require.Empty(t, output.String())
				}
				require.NotContains(t, output.String()+diagnostic.String(), "private-value")
				if code == 65 {
					require.Zero(t, calls.Load())
				}
			})
		}
	}
}
