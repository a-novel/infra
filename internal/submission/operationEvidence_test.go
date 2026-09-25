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

func TestOperationInspection(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, record, field string
		value               any
		code                int
		want                string
	}{
		{name: "Success/Held", want: "42 (held)"},
		{name: "Success/Deleted", want: "42 (no live guard)"},
		{name: "Success/Successor", want: "another generation is live"},
		{name: "Success/Incomplete", want: "not recorded; native work may"},
		{name: "Error/FinishNative", code: 70},
		{name: "Error/GuardChanged", code: 70},
		{name: "Error/Denied", code: 70},
		{name: "Error/MissingReceipt", code: 70},
		{name: "Error/Unregistered", code: 65},
		{name: "Error/Duplicate", code: 70},
		{"Error/GuardHash", "guard", "sha256", strings.Repeat("0", 64), 70, ""},
		{"Error/GuardKind", "guard", "kind", "future-kind", 70, ""},
		{"Error/GuardVersion", "guard", "schemaVersion", 2, 70, ""},
		{"Error/Run", "guard", "runId", "unsafe\nprivate-value", 70, ""},
		{"Error/PeerProject", "config", "project_id", "agora-peer-test", 70, ""},
		{"Error/UnknownConfiguration", "config", "unexpected", "private-value", 70, ""},
		{"Error/PointerScope", "pointer", "bucket", "peer-bucket", 70, ""},
		{"Error/PointerPath", "pointer", "object", "services/agora-peer-test/production/native-success/release-1.json", 70, ""},
		{"Error/PointerGeneration", "pointer", "generation", "0", 70, ""},
		{"Error/RecordGeneration", "receipt", "guardGeneration", "41", 70, ""},
		{"Error/RecordConfiguration", "receipt", "configuration", map[string]any{}, 70, ""},
		{"Error/RecordVersion", "receipt", "schemaVersion", 2, 70, ""},
		{"Error/RecordedAt", "receipt", "completedAt", "private-value", 70, ""},
		{"Error/ReleaseIdentity", "release", "name", "projects/999999/locations/europe-west1/deliveryPipelines/peer/releases/release-1", 70, ""},
		{"Error/ReleaseRender", "release", "renderState", "FAILED", 70, ""},
		{"Error/RolloutIdentity", "rollout", "annotations", map[string]string{}, 70, ""},
		{"Error/RolloutApproval", "rollout", "approvalState", "NEEDS_APPROVAL", 70, ""},
		{"Error/SkippedVerification", "rollout", "phases", []any{}, 70, ""},
	} {
		t.Run(testCase.name, func(t *testing.T) {
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
			var calls, liveReads atomic.Int32
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls.Add(1)
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
			args := []string{"operation", "inspect", state, "agora-json-keys-test", "42"}
			if testCase.name == "Error/Unregistered" {
				delete(env, "FOUNDATION_CONFIG")
			}
			if testCase.name == "Error/FinishNative" {
				args = []string{"operation", "finish", state, "service-release", "agora-json-keys-test", "42", "FINISH json-keys 42"}
				env["SERVICE_OPERATION_RECOVERY_ENABLED"] = "true"
				env["GITHUB_WORKFLOW_REF"] = "a-novel/infra/.github/workflows/foundation.yaml@refs/heads/master"
			}
			var output, diagnostic bytes.Buffer
			code := custody.Run(t.Context(), args, func(key string) string { return env[key] },
				func(context.Context, io.Writer, string, ...string) error {
					t.Error("inspection ran a command")
					return nil
				},
				&output, &diagnostic, option.WithEndpoint(server.URL), option.WithoutAuthentication())
			require.Equal(t, testCase.code, code, "%s", &diagnostic)
			if testCase.code == 0 {
				require.Contains(t, output.String(), testCase.want)
			} else {
				require.Empty(t, output.String())
			}
			require.NotContains(t, output.String()+diagnostic.String(), "private-value")
			if testCase.code == 65 {
				require.Zero(t, calls.Load())
			}
		})
	}
}
