package submission_test

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"cloud.google.com/go/deploy/apiv1/deploypb"
	"cloud.google.com/go/longrunning/autogen/longrunningpb"
	"github.com/stretchr/testify/require"
	"google.golang.org/api/option"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/anypb"

	"github.com/a-novel/infra/internal/submission"
)

func TestRollout(t *testing.T) {
	t.Parallel()
	type result struct {
		creates, records, reconcile int
		readOnly                    bool
	}
	for _, testCase := range []struct {
		name, failure string
		concurrent    bool
		prepare       func(*deploypb.Release, *deploypb.Target)
		want          result
	}{
		{name: "Success/ApprovalThenCompletion", want: result{1, 2, 0, true}},
		{name: "Success/ConcurrentDifferentUUIDs", concurrent: true, want: result{1, 2, 0, true}},
		{name: "PendingApproval", failure: "pending", want: result{1, 2, 1, true}},
		{name: "IntentDenied", failure: "intent-denied", want: result{0, 0, 1, true}},
		{name: "IntentAckLost", failure: "intent", want: result{0, 1, 1, true}},
		{name: "CreateDenied", failure: "create-denied", want: result{1, 1, 1, true}},
		{name: "CreateAckLost", failure: "create", want: result{1, 1, 0, true}},
		{name: "OperationAckLost", failure: "operation", want: result{1, 2, 0, true}},
		{name: "OperationScope", failure: "operation-scope", want: result{1, 1, 0, true}},
		{name: "WaitInterrupted", failure: "wait", want: result{1, 2, 0, true}},
		{name: "NativeConflict", failure: "native-conflict", want: result{1, 2, 1, true}},
		{name: "StoredPolicyOverride", failure: "stored-conflict", want: result{1, 2, 1, true}},
		{name: "StoredUnknownField", failure: "stored-unknown", want: result{1, 2, 1, true}},
		{name: "RecreatedRelease", failure: "release-uid", want: result{1, 2, 1, true}},
		{name: "StillRendering", prepare: func(r *deploypb.Release, _ *deploypb.Target) {
			r.RenderState = deploypb.Release_IN_PROGRESS
		}, want: result{0, 0, 1, true}},
		{name: "Abandoned", prepare: func(r *deploypb.Release, _ *deploypb.Target) {
			r.Abandoned = true
		}, want: result{0, 0, 1, true}},
		{name: "NoReleaseUID", prepare: func(r *deploypb.Release, _ *deploypb.Target) {
			r.Uid = ""
		}, want: result{0, 0, 1, true}},
		{name: "ReleaseConflict", prepare: func(r *deploypb.Release, _ *deploypb.Target) {
			r.DeployParameters["masterKeyVersion"] = "99"
		}, want: result{0, 0, 1, true}},
		{name: "SnapshotApprovalAbsent", prepare: func(r *deploypb.Release, _ *deploypb.Target) {
			r.TargetSnapshots[0].RequireApproval = false
		}, want: result{0, 0, 1, true}},
		{name: "SnapshotPeerTarget", prepare: func(r *deploypb.Release, _ *deploypb.Target) {
			r.TargetSnapshots[0].Name += "-peer"
		}, want: result{0, 0, 1, true}},
		{name: "SnapshotPeerProject", prepare: func(r *deploypb.Release, _ *deploypb.Target) {
			r.TargetSnapshots[0].GetRun().Location = "projects/999999/locations/europe-west1"
		}, want: result{0, 0, 1, true}},
		{name: "NoSnapshot", prepare: func(r *deploypb.Release, _ *deploypb.Target) {
			r.TargetSnapshots = nil
		}, want: result{0, 0, 1, true}},
		{name: "CurrentApprovalAbsent", prepare: func(_ *deploypb.Release, target *deploypb.Target) {
			target.RequireApproval = false
		}, want: result{0, 0, 1, true}},
		{name: "CurrentTargetRecreated", prepare: func(_ *deploypb.Release, target *deploypb.Target) {
			target.Uid = "recreated"
		}, want: result{0, 0, 1, true}},
		{name: "TargetReadDenied", failure: "target", want: result{0, 0, 1, true}},
		{name: "UUIDReusedAcrossOperations", failure: "reuse-uuid", want: result{0, 0, 1, true}},
		{name: "MigrationEvidenceMissing", failure: "migration-missing", want: result{0, 0, 1, true}},
		{name: "MigrationEvidenceConflict", failure: "migration-conflict", want: result{0, 0, 1, true}},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			releaseRequest := fixture(t)
			release := proto.Clone(releaseRequest.Release).(*deploypb.Release)
			release.RenderState, release.Uid = deploypb.Release_SUCCEEDED, "release-uid"
			target := &deploypb.Target{
				Name: "projects/123456/locations/europe-west1/targets/agora-json-keys-grpc",
				Uid:  "target-uid", RequireApproval: true,
				DeploymentTarget: &deploypb.Target_Run{Run: &deploypb.CloudRunLocation{
					Location: "projects/agora-json-keys-test/locations/europe-west1",
				}},
			}
			release.TargetSnapshots = []*deploypb.Target{proto.Clone(target).(*deploypb.Target)}
			if testCase.prepare != nil {
				testCase.prepare(release, target)
			}
			rolloutIntent := strings.TrimSuffix(intent, ".json") + ".rollout.json"
			rolloutName := release.Name + "/rollouts/production"
			objects := map[string][]byte{intent: wire(t, releaseRequest)}
			for name, data := range migrationRecords(t, release) {
				objects[name] = data
			}
			migrationResult := strings.TrimSuffix(intent, ".json") + ".migration.execution.json"
			switch testCase.failure {
			case "migration-missing":
				delete(objects, migrationResult)
			case "migration-conflict":
				objects[migrationResult] = []byte(`{"job":"peer"}`)
			}
			initialRecords := len(objects)
			var native *deploypb.Rollout
			var mutex sync.Mutex
			creates, writes := 0, 0
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				mutex.Lock()
				defer mutex.Unlock()
				w.Header().Set("Content-Type", "application/json")
				switch {
				case r.Method == http.MethodGet && r.URL.Path == "/v1/"+release.Name:
					_, _ = w.Write(wire(t, release))
				case r.Method == http.MethodGet && r.URL.Path == "/v1/"+target.Name:
					if testCase.failure == "target" {
						http.Error(w, "private-provider-detail", http.StatusForbidden)
						return
					}
					_, _ = w.Write(wire(t, target))
				case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/b/"+bucket+"/o/"):
					if data, exists := objects[strings.TrimPrefix(r.URL.Path, "/b/"+bucket+"/o/")]; exists {
						_, _ = w.Write(data)
					} else {
						http.NotFound(w, r)
					}
				case r.Method == http.MethodPost && r.URL.Path == "/upload/storage/v1/b/"+bucket+"/o":
					writes++
					metadata, data := upload(t, r)
					if r.URL.Query().Get("ifGenerationMatch") != "0" {
						t.Error("private record is not create-only")
					}
					stage := "intent"
					switch metadata.Name {
					case rolloutIntent:
					case strings.TrimSuffix(rolloutIntent, ".json") + ".operation.json":
						stage = "operation"
						operation := &longrunningpb.Operation{}
						if protojson.Unmarshal(data, operation) != nil || operation.Name != operationName {
							t.Error("wrong durable rollout operation")
						}
					default:
						t.Error("write outside rollout intent namespace")
					}
					if _, exists := objects[metadata.Name]; exists {
						http.Error(w, "reserved", http.StatusPreconditionFailed)
						return
					}
					if testCase.failure == "intent-denied" {
						http.Error(w, "private-provider-detail", http.StatusForbidden)
						return
					}
					objects[metadata.Name] = data
					if testCase.failure == stage {
						http.Error(w, "private-provider-detail", http.StatusServiceUnavailable)
						return
					}
					metadata.Bucket, metadata.Generation = bucket, 1
					_ = json.NewEncoder(w).Encode(metadata)
				case r.Method == http.MethodPost && r.URL.Path == "/v1/"+release.Name+"/rollouts":
					creates++
					reserved, posted := &deploypb.CreateRolloutRequest{}, &deploypb.Rollout{}
					data, err := io.ReadAll(r.Body)
					if err != nil || protojson.Unmarshal(data, posted) != nil || protojson.Unmarshal(objects[rolloutIntent], reserved) != nil {
						t.Error("dispatch without readable reserved rollout intent")
					}
					expected := &deploypb.CreateRolloutRequest{
						Parent: release.Name, RolloutId: "production", StartingPhaseId: "canary-0",
						RequestId: r.URL.Query().Get("requestId"),
						Rollout: &deploypb.Rollout{
							Name: rolloutName, TargetId: "agora-json-keys-grpc",
							Annotations: map[string]string{"request-id": r.URL.Query().Get("requestId"), "release-uid": release.Uid},
						},
					}
					if !proto.Equal(reserved, expected) || !proto.Equal(posted, expected.Rollout) {
						t.Error("native request differs from reserved policy")
					}
					for key, want := range map[string]string{"rolloutId": "production", "startingPhaseId": "canary-0", "overrideDeployPolicy": "", "validateOnly": ""} {
						if r.URL.Query().Get(key) != want {
							t.Errorf("unexpected rollout query %s", key)
						}
					}
					if testCase.failure == "create-denied" {
						http.Error(w, "private-provider-detail", http.StatusForbidden)
						return
					}
					native = posted
					native.State, native.ApprovalState = deploypb.Rollout_PENDING_APPROVAL, deploypb.Rollout_NEEDS_APPROVAL
					if testCase.failure == "native-conflict" {
						native.Annotations["release-uid"] = "peer"
					}
					if testCase.failure == "create" {
						http.Error(w, "private-provider-detail", http.StatusServiceUnavailable)
						return
					}
					operation := &longrunningpb.Operation{Name: operationName}
					if testCase.failure == "operation-scope" {
						operation.Name = strings.ReplaceAll(operationName, "123456", "999999")
					}
					_, _ = w.Write(wire(t, operation))
				case r.Method == http.MethodGet && r.URL.Path == "/v1/"+operationName:
					if testCase.failure == "wait" {
						cancel()
						return
					}
					response, err := anypb.New(native)
					if err != nil {
						t.Error(err)
					}
					_, _ = w.Write(wire(t, &longrunningpb.Operation{Name: operationName, Done: true, Result: &longrunningpb.Operation_Response{Response: response}}))
				case r.Method == http.MethodGet && r.URL.Path == "/v1/"+rolloutName:
					if native == nil {
						http.NotFound(w, r)
						return
					}
					_, _ = w.Write(wire(t, native))
				default:
					t.Errorf("unexpected cloud operation: %s %s", r.Method, r.URL.Path)
					http.NotFound(w, r)
				}
			}))
			defer server.Close()
			options := []option.ClientOption{option.WithEndpoint(server.URL), option.WithoutAuthentication()}
			attempts := 1
			if testCase.concurrent {
				attempts = 2
			}
			var wait sync.WaitGroup
			for index := range attempts {
				wait.Go(func() {
					requestID := "22222222-2222-4222-8222-222222222222"
					if index == 1 {
						requestID = "33333333-3333-4333-8333-333333333333"
					}
					if testCase.failure == "reuse-uuid" {
						requestID = releaseRequest.RequestId
					}
					args := arguments(t, "submit-rollout", "--request-id="+requestID)
					args = append(args, releaseRequest.ReleaseId)
					var output bytes.Buffer
					code := submission.Run(ctx, args, &output, &output, options...)
					if code != 1 || strings.Contains(output.String(), "private-provider-detail") {
						t.Errorf("submission must remain incomplete without disclosing private errors: %s", &output)
					}
				})
			}
			wait.Wait()
			mutex.Lock()
			if native != nil && testCase.failure != "pending" {
				completeRollout(t, native)
			}
			switch testCase.failure {
			case "stored-conflict":
				changed := &deploypb.CreateRolloutRequest{}
				if err := protojson.Unmarshal(objects[rolloutIntent], changed); err != nil {
					t.Fatal(err)
				}
				changed.StartingPhaseId = "stable"
				objects[rolloutIntent] = wire(t, changed)
			case "stored-unknown":
				objects[rolloutIntent] = []byte("{\"private-input\":true}")
			case "release-uid":
				release.Uid = "recreated-release"
			}
			beforeWrites := writes
			mutex.Unlock()
			var output bytes.Buffer
			reconciled := submission.Run(t.Context(), arguments(t, "reconcile-rollout", releaseRequest.ReleaseId), &output, &output, options...)
			mutex.Lock()
			got := result{creates, len(objects) - initialRecords, reconciled, writes == beforeWrites}
			mutex.Unlock()
			require.Equal(t, testCase.want, got, "reconcile output: %s", &output)
			if reconciled == 0 {
				require.Contains(t, output.String(), "Durable success receipt remains pending.")
			}
		})
	}
}
