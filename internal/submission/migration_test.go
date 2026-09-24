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
	"time"

	"cloud.google.com/go/deploy/apiv1/deploypb"
	"cloud.google.com/go/longrunning/autogen/longrunningpb"
	"cloud.google.com/go/run/apiv2/runpb"
	"github.com/stretchr/testify/require"
	"google.golang.org/api/option"
	"google.golang.org/genproto/googleapis/rpc/status"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/anypb"
	"google.golang.org/protobuf/types/known/durationpb"
	"google.golang.org/protobuf/types/known/timestamppb"

	"github.com/a-novel/infra/internal/submission"
)

func TestMigration(t *testing.T) {
	t.Parallel()
	type result struct{ submit, reconcile, runs, records int }
	for _, testCase := range []struct {
		name, failure string
		change        func(*runpb.Job, *runpb.Execution)
		want          result
	}{
		{"Succeeded", "", nil, result{0, 0, 1, 3}},
		{"ConcurrentSameRelease", "concurrent", nil, result{0, 0, 1, 3}},
		{"NoInitialExecutionMetadata", "no-metadata", nil, result{0, 0, 1, 3}},
		{"ReservationAckLost", "intent", nil, result{1, 1, 0, 1}},
		{"RunAckLost", "run", nil, result{1, 1, 1, 1}},
		{"OperationAckLost", "operation", nil, result{1, 0, 1, 3}},
		{"WaitInterrupted", "wait", nil, result{1, 0, 1, 3}},
		{"EvidenceAckLost", "execution", nil, result{0, 0, 1, 3}},
		{"EvidenceDenied", "execution-denied", nil, result{1, 1, 1, 2}},
		{"EvidenceConflict", "execution-conflict", nil, result{1, 1, 1, 3}},
		{"JobChangedAfterExecution", "job-changed", nil, result{0, 0, 1, 3}},
		{"FailedOperation", "failed", nil, result{1, 1, 1, 2}},
		{"WrongOperationScope", "scope", nil, result{1, 1, 1, 1}},
		{"ChangedReleaseUID", "release-uid", nil, result{0, 1, 1, 3}},
		{"MissingJobUID", "", func(j *runpb.Job, _ *runpb.Execution) { j.Uid = "" }, result{1, 1, 0, 0}},
		{"UnreadyJob", "", func(j *runpb.Job, _ *runpb.Execution) { j.Reconciling = true }, result{1, 1, 0, 0}},
		{"WrongImage", "", func(j *runpb.Job, _ *runpb.Execution) { j.Template.Template.Containers[0].Image += "bad" }, result{1, 1, 0, 0}},
		{"ImplicitRetries", "", func(j *runpb.Job, _ *runpb.Execution) { j.Template.Template.Retries = nil }, result{1, 1, 0, 0}},
		{"TaskRetryEnabled", "", func(j *runpb.Job, _ *runpb.Execution) {
			j.Template.Template.Retries = &runpb.TaskTemplate_MaxRetries{MaxRetries: 1}
		}, result{1, 1, 0, 0}},
		{"EntrypointOverride", "", func(j *runpb.Job, _ *runpb.Execution) { j.Template.Template.Containers[0].Args = []string{"unsafe"} }, result{1, 1, 0, 0}},
		{"OtherExecution", "", func(_ *runpb.Job, e *runpb.Execution) { e.Uid = "33333333-3333-4333-8333-333333333333" }, result{1, 1, 1, 2}},
		{"ExecutionOverride", "", func(_ *runpb.Job, e *runpb.Execution) { e.Template.Containers[0].Args = []string{"unsafe"} }, result{1, 1, 1, 2}},
		{"CancelledTask", "", func(_ *runpb.Job, e *runpb.Execution) { e.CancelledCount = 1 }, result{1, 1, 1, 2}},
		{"RetriedTask", "", func(_ *runpb.Job, e *runpb.Execution) { e.RetriedCount = 1 }, result{1, 1, 1, 2}},
		{"IncompleteTask", "", func(_ *runpb.Job, e *runpb.Execution) { e.CompletionTime = nil }, result{1, 1, 1, 2}},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			request := fixture(t)
			release := proto.Clone(request.Release).(*deploypb.Release)
			release.Uid, release.RenderState = "release-uid", deploypb.Release_SUCCEEDED
			job, execution := migrationFixture(t, release)
			jobUID, image := job.Uid, job.Template.Template.Containers[0].Image
			metadata, err := anypb.New(&runpb.Execution{Name: execution.Name, Uid: execution.Uid})
			require.NoError(t, err)
			if testCase.change != nil {
				testCase.change(job, execution)
			}
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			var mutex sync.Mutex
			objects := map[string][]byte{intent: wire(t, request)}
			migrationName := strings.TrimSuffix(intent, ".json") + ".migration.json"
			runs := 0
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				mutex.Lock()
				defer mutex.Unlock()
				w.Header().Set("Content-Type", "application/json")
				switch {
				case r.Method == http.MethodGet && r.URL.Path == "/v1/"+release.Name:
					_, _ = w.Write(wire(t, release))
				case r.Method == http.MethodGet && r.URL.Path == "/v2/"+job.Name:
					_, _ = w.Write(wire(t, job))
				case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/b/"+bucket+"/o/"):
					if data, exists := objects[strings.TrimPrefix(r.URL.Path, "/b/"+bucket+"/o/")]; exists {
						_, _ = w.Write(data)
					} else {
						http.NotFound(w, r)
					}
				case r.Method == http.MethodPost && r.URL.Path == "/upload/storage/v1/b/"+bucket+"/o":
					object, data := upload(t, r)
					if r.URL.Query().Get("ifGenerationMatch") != "0" || !strings.HasPrefix(object.Name, strings.TrimSuffix(migrationName, ".json")) {
						t.Error("expected create-only migration evidence in the exact release namespace")
					}
					if _, exists := objects[object.Name]; exists {
						w.WriteHeader(http.StatusPreconditionFailed)
						return
					}
					if strings.HasSuffix(object.Name, ".execution.json") && testCase.failure == "execution-denied" {
						http.Error(w, "private-provider-detail", http.StatusForbidden)
						return
					}
					objects[object.Name] = data
					stage := "intent"
					for _, suffix := range []string{"operation", "execution"} {
						if strings.HasSuffix(object.Name, "."+suffix+".json") {
							stage = suffix
						}
					}
					if stage == "execution" && testCase.failure == "execution-conflict" {
						objects[object.Name] = []byte(`{"job":"peer"}`)
					}
					if testCase.failure == stage {
						http.Error(w, "private-provider-detail", http.StatusServiceUnavailable)
						return
					}
					object.Bucket, object.Generation = bucket, 1
					_ = json.NewEncoder(w).Encode(object)
				case r.Method == http.MethodPost && r.URL.Path == "/v2/"+job.Name+":run":
					runs++
					var reserved struct {
						ReleaseUID string          `json:"releaseUid"`
						Job        json.RawMessage `json:"job"`
					}
					saved := new(runpb.Job)
					if json.Unmarshal(objects[migrationName], &reserved) != nil || reserved.ReleaseUID != release.Uid ||
						protojson.Unmarshal(reserved.Job, saved) != nil || !proto.Equal(saved, job) {
						t.Error("RunJob was not preceded by the exact durable release/job reservation")
					}
					data, err := io.ReadAll(r.Body)
					posted := new(runpb.RunJobRequest)
					if err != nil || protojson.Unmarshal(data, posted) != nil || !proto.Equal(posted, &runpb.RunJobRequest{Name: job.Name, Etag: job.Etag}) {
						t.Error("RunJob requires the inspected etag and no overrides")
					}
					if testCase.failure == "run" {
						http.Error(w, "private-provider-detail", http.StatusServiceUnavailable)
						return
					}
					operation := &longrunningpb.Operation{Name: operationName, Metadata: metadata}
					if testCase.failure == "no-metadata" {
						operation.Metadata = nil
					}
					if testCase.failure == "scope" {
						operation.Name = strings.ReplaceAll(operationName, "123456", "999999")
					}
					_, _ = w.Write(wire(t, operation))
				case r.Method == http.MethodGet && r.URL.Path == "/v2/"+operationName:
					if _, exists := objects[strings.TrimSuffix(migrationName, ".json")+".operation.json"]; !exists {
						t.Error("waiting without a recorded operation")
					}
					if testCase.failure == "wait" && ctx.Err() == nil {
						cancel()
						return
					}
					response, err := anypb.New(execution)
					if err != nil {
						t.Error(err)
					}
					operation := &longrunningpb.Operation{Name: operationName, Done: true, Result: &longrunningpb.Operation_Response{Response: response}}
					if testCase.failure == "failed" {
						operation.Result = &longrunningpb.Operation_Error{Error: &status.Status{Code: 9, Message: "private-provider-detail"}}
					}
					_, _ = w.Write(wire(t, operation))
				default:
					t.Errorf("unexpected cloud operation: %s %s", r.Method, r.URL.Path)
					w.WriteHeader(http.StatusForbidden)
				}
			}))
			defer server.Close()
			options := []option.ClientOption{option.WithEndpoint(server.URL), option.WithoutAuthentication()}
			args := append(arguments(t, "submit-migration", "--job-uid="+jobUID), "--image="+image, request.ReleaseId)
			var output bytes.Buffer
			concurrent := make(chan int, 1)
			if testCase.failure == "concurrent" {
				go func() {
					var duplicate bytes.Buffer
					concurrent <- submission.Run(ctx, args, &duplicate, &duplicate, options...)
				}()
			}
			got := result{submit: submission.Run(ctx, args, &output, &output, options...)}
			if testCase.failure == "concurrent" {
				other := <-concurrent
				require.Equal(t, 1, got.submit+other, "only one concurrent caller may succeed")
				got.submit = min(got.submit, other)
			}
			// A fresh process with the same arguments must never obtain dispatch authority again.
			replayed := submission.Run(t.Context(), args, &output, &output, options...)
			mutex.Lock()
			if testCase.failure == "release-uid" {
				release.Uid = "recreated-release"
			}
			if testCase.failure == "job-changed" {
				job.Template.Template.Containers[0].Image = "later-image"
			}
			beforeRuns := runs
			mutex.Unlock()
			got.reconcile = submission.Run(t.Context(), arguments(t, "reconcile-migration", request.ReleaseId), &output, &output, options...)
			mutex.Lock()
			got.runs, got.records = runs, len(objects)-1
			mutex.Unlock()
			require.Equal(t, testCase.want, got, "%s", &output)
			require.Equal(t, 1, replayed, "reserved migrations cannot be submitted again")
			require.Equal(t, beforeRuns, got.runs, "reconciliation must not execute a job")
			require.NotContains(t, output.String(), "private-provider-detail")
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
