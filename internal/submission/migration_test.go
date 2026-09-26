package submission_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"cloud.google.com/go/deploy/apiv1/deploypb"
	"cloud.google.com/go/longrunning/autogen/longrunningpb"
	"cloud.google.com/go/run/apiv2/runpb"
	"github.com/stretchr/testify/require"
	"google.golang.org/api/option"
	"google.golang.org/genproto/googleapis/rpc/status"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/anypb"
	"google.golang.org/protobuf/types/known/durationpb"
	"google.golang.org/protobuf/types/known/timestamppb"

	"github.com/a-novel/infra/internal/submission"
)

func TestReconcileMigration(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name   string
		change func(*runpb.Job, *runpb.Execution)
		want   int
	}{
		{"Succeeded", nil, 0},
		{"NoInitialMetadata", nil, 0},
		{"EvidenceAckLost", nil, 0},
		{"EvidenceDenied", nil, 1},
		{"EvidenceConflict", nil, 1},
		{"OperationMissing", nil, 1},
		{"FailedOperation", nil, 1},
		{"WrongOperationScope", nil, 1},
		{"ChangedReleaseUID", nil, 1},
		{"MissingJobUID", func(j *runpb.Job, _ *runpb.Execution) { j.Uid = "" }, 1},
		{"UnreadyJob", func(j *runpb.Job, _ *runpb.Execution) { j.Reconciling = true }, 1},
		{"WrongImage", func(j *runpb.Job, _ *runpb.Execution) { j.Template.Template.Containers[0].Image += "bad" }, 1},
		{"ImplicitRetries", func(j *runpb.Job, _ *runpb.Execution) { j.Template.Template.Retries = nil }, 1},
		{"TaskRetryEnabled", func(j *runpb.Job, _ *runpb.Execution) {
			j.Template.Template.Retries = &runpb.TaskTemplate_MaxRetries{MaxRetries: 1}
		}, 1},
		{"EntrypointOverride", func(j *runpb.Job, _ *runpb.Execution) { j.Template.Template.Containers[0].Args = []string{"unsafe"} }, 1},
		{"OtherExecution", func(_ *runpb.Job, e *runpb.Execution) { e.Uid = "33333333-3333-4333-8333-333333333333" }, 1},
		{"ExecutionOverride", func(_ *runpb.Job, e *runpb.Execution) { e.Template.Containers[0].Args = []string{"unsafe"} }, 1},
		{"CancelledTask", func(_ *runpb.Job, e *runpb.Execution) { e.CancelledCount = 1 }, 1},
		{"RetriedTask", func(_ *runpb.Job, e *runpb.Execution) { e.RetriedCount = 1 }, 1},
		{"IncompleteTask", func(_ *runpb.Job, e *runpb.Execution) { e.CompletionTime = nil }, 1},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			request := fixture(t)
			release := proto.Clone(request.Release).(*deploypb.Release)
			release.Uid, release.RenderState = "release-uid", deploypb.Release_SUCCEEDED
			job, execution := migrationFixture(t, release)
			metadata, err := anypb.New(&runpb.Execution{Name: execution.Name, Uid: execution.Uid})
			require.NoError(t, err)
			if testCase.change != nil {
				testCase.change(job, execution)
			}
			reserved := &longrunningpb.Operation{Name: operationName, Metadata: metadata}
			switch testCase.name {
			case "NoInitialMetadata":
				reserved.Metadata = nil
			case "WrongOperationScope":
				reserved.Name = strings.ReplaceAll(operationName, "123456", "999999")
			}
			migrationName := strings.TrimSuffix(intent, ".json") + ".migration"
			objects := map[string][]byte{
				intent: wire(t, request),
				migrationName + ".json": encodeOperation(t, map[string]any{
					"schemaVersion": 1, "releaseUid": release.Uid, "job": json.RawMessage(wire(t, job)),
				}),
				migrationName + ".operation.json": wire(t, reserved),
			}
			switch testCase.name {
			case "OperationMissing":
				delete(objects, migrationName+".operation.json")
			case "ChangedReleaseUID":
				release.Uid = "recreated-release"
			case "EvidenceConflict":
				objects[migrationName+".execution.json"] = []byte(`{"job":"peer"}`)
			}
			var mutex sync.Mutex
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				mutex.Lock()
				defer mutex.Unlock()
				w.Header().Set("Content-Type", "application/json")
				switch {
				case r.Method == http.MethodGet && r.URL.Path == "/v1/"+release.Name:
					_, _ = w.Write(wire(t, release))
				case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/b/"+bucket+"/o/"):
					data, exists := objects[strings.TrimPrefix(r.URL.Path, "/b/"+bucket+"/o/")]
					if !exists {
						http.NotFound(w, r)
					} else {
						_, _ = w.Write(data)
					}
				case r.Method == http.MethodPost && r.URL.Path == "/upload/storage/v1/b/"+bucket+"/o":
					object, data := upload(t, r)
					if r.URL.Query().Get("ifGenerationMatch") != "0" || object.Name != migrationName+".execution.json" {
						t.Error("reconciliation may only create exact execution evidence")
					}
					if _, exists := objects[object.Name]; exists {
						w.WriteHeader(http.StatusPreconditionFailed)
						return
					}
					if testCase.name == "EvidenceDenied" {
						http.Error(w, "private-provider-detail", http.StatusForbidden)
						return
					}
					objects[object.Name] = data
					if testCase.name == "EvidenceAckLost" {
						http.Error(w, "private-provider-detail", http.StatusServiceUnavailable)
						return
					}
					object.Bucket, object.Generation = bucket, 1
					_ = json.NewEncoder(w).Encode(object)
				case r.Method == http.MethodGet && r.URL.Path == "/v2/"+operationName:
					response, err := anypb.New(execution)
					if err != nil {
						panic(err)
					}
					operation := &longrunningpb.Operation{Name: operationName, Done: true, Result: &longrunningpb.Operation_Response{Response: response}}
					if testCase.name == "FailedOperation" {
						operation.Result = &longrunningpb.Operation_Error{Error: &status.Status{Code: 9, Message: "private-provider-detail"}}
					}
					_, _ = w.Write(wire(t, operation))
				default:
					t.Errorf("unexpected cloud operation: %s %s", r.Method, r.URL.Path)
					w.WriteHeader(http.StatusForbidden)
				}
			}))
			defer server.Close()
			for range 2 {
				var output bytes.Buffer
				code := submission.Run(t.Context(), arguments(t, "reconcile-migration", request.ReleaseId), &output, &output,
					option.WithEndpoint(server.URL), option.WithoutAuthentication())
				require.Equal(t, testCase.want, code, "%s", &output)
				require.NotContains(t, output.String(), "private-provider-detail")
			}
		})
	}
}

func migrationFixture(t *testing.T, release *deploypb.Release) (*runpb.Job, *runpb.Execution) {
	t.Helper()
	job := &runpb.Job{
		Name: "projects/123456/locations/europe-west1/jobs/agora-json-keys-migrations", Uid: "11111111-1111-4111-8111-111111111111", Etag: "reviewed-etag",
		Generation: 1, ObservedGeneration: 1, TerminalCondition: &runpb.Condition{Type: "Ready", State: runpb.Condition_CONDITION_SUCCEEDED},
		Template: &runpb.ExecutionTemplate{TaskCount: 1, Parallelism: 1, Template: &runpb.TaskTemplate{
			ServiceAccount: release.DeployParameters["runtimeServiceAccount"], Timeout: durationpb.New(600 * time.Second), Retries: &runpb.TaskTemplate_MaxRetries{MaxRetries: 0},
			Containers: []*runpb.Container{{Name: "migrations", Image: "europe-west1-docker.pkg.dev/agora-json-keys-test/agora-production/service-json-keys/jobs/migrations@sha256:" + strings.Repeat("b", 64)}},
		}},
	}
	execution := &runpb.Execution{
		Name: job.Name + "/executions/migrations-123", Uid: "22222222-2222-4222-8222-222222222222", Job: job.Name,
		TaskCount: 1, Parallelism: 1, SucceededCount: 1, CompletionTime: timestamppb.New(time.Unix(1000, 0)),
		Template: proto.Clone(job.Template.Template).(*runpb.TaskTemplate), Conditions: []*runpb.Condition{{Type: "Completed", State: runpb.Condition_CONDITION_SUCCEEDED}},
	}
	return job, execution
}
