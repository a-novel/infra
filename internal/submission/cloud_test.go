package submission_test

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
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

func TestCloud(t *testing.T) {
	t.Parallel()
	sourceDirectory := sourceCheckout(t)
	type result struct {
		submit                      []int
		reconcile, creates, records int
	}
	for _, testCase := range []struct {
		name, failure string
		concurrent    bool
		render        deploypb.Release_RenderState
		want          result
	}{
		{"Rendered", "", false, deploypb.Release_SUCCEEDED, result{[]int{0}, 0, 1, 2}},
		{"RenderingIsNotDeployment", "", false, deploypb.Release_IN_PROGRESS, result{[]int{0}, 0, 1, 2}},
		{"ConcurrentSameIdentity", "", true, deploypb.Release_SUCCEEDED, result{[]int{0, 1}, 0, 1, 2}},
		{"IntentDenied", "intent-denied", false, deploypb.Release_SUCCEEDED, result{[]int{1}, 1, 0, 0}},
		{"IntentAckLost", "intent", false, deploypb.Release_SUCCEEDED, result{[]int{1}, 1, 0, 1}},
		{"CreateDenied", "create-denied", false, deploypb.Release_SUCCEEDED, result{[]int{1}, 1, 1, 1}},
		{"CreateAckLost", "create", false, deploypb.Release_SUCCEEDED, result{[]int{1}, 0, 1, 1}},
		{"OperationAckLost", "operation", false, deploypb.Release_SUCCEEDED, result{[]int{1}, 0, 1, 2}},
		{"OperationScopeMismatch", "operation-scope", false, deploypb.Release_SUCCEEDED, result{[]int{1}, 0, 1, 1}},
		{"WaitInterrupted", "wait", false, deploypb.Release_SUCCEEDED, result{[]int{1}, 0, 1, 2}},
		{"RenderFailed", "", false, deploypb.Release_FAILED, result{[]int{1}, 1, 1, 2}},
		{"UnknownRender", "", false, deploypb.Release_RENDER_STATE_UNSPECIFIED, result{[]int{1}, 1, 1, 2}},
		{"NativeConflict", "conflict", false, deploypb.Release_SUCCEEDED, result{[]int{1}, 1, 1, 2}},
		{"Abandoned", "abandoned", false, deploypb.Release_SUCCEEDED, result{[]int{1}, 1, 1, 2}},
		{"StoredIdentityConflict", "stored-conflict", false, deploypb.Release_SUCCEEDED, result{[]int{0}, 1, 1, 2}},
		{"SourceMissing", "source-missing", false, deploypb.Release_SUCCEEDED, result{[]int{1}, 1, 0, 0}},
		{"SourceConflict", "source-conflict", false, deploypb.Release_SUCCEEDED, result{[]int{1}, 1, 0, 0}},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			request := fixture(t)
			sourceName := bindSource(t, request, sourceDirectory)
			path := filepath.Join(t.TempDir(), "request.json")
			require.NoError(t, os.WriteFile(path, wire(t, request), 0o600))
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			var mutex sync.Mutex
			objects := map[string][]byte{}
			var native *deploypb.Release
			var source []byte
			creates, writes := 0, 0
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				mutex.Lock()
				defer mutex.Unlock()
				w.Header().Set("Content-Type", "application/json")
				switch {
				case r.Method == http.MethodPost && r.URL.Path == "/upload/storage/v1/b/"+bucket+"/o":
					metadata, data := upload(t, r)
					if r.URL.Query().Get("ifGenerationMatch") != "0" {
						t.Error("upload did not require an absent object")
					}
					if metadata.Name == sourceName {
						source = data
						metadata.Bucket, metadata.Generation = bucket, 1
						_ = json.NewEncoder(w).Encode(metadata)
						return
					}
					writes++
					if _, exists := objects[metadata.Name]; exists {
						http.Error(w, "already reserved", http.StatusPreconditionFailed)
						return
					}
					stage := "intent"
					if strings.HasSuffix(metadata.Name, ".operation.json") {
						stage = "operation"
						operation := new(longrunningpb.Operation)
						if err := protojson.Unmarshal(data, operation); err != nil || operation.Name != operationName {
							t.Error("wrong durable operation identity")
						}
					} else if metadata.Name != intent {
						t.Error("write outside exact intent namespace")
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
				case r.Method == http.MethodPost && r.URL.Path == "/v1/"+request.Parent+"/releases":
					creates++
					reserved := new(deploypb.CreateReleaseRequest)
					data, err := io.ReadAll(r.Body)
					posted := new(deploypb.Release)
					if err != nil || protojson.Unmarshal(data, posted) != nil || protojson.Unmarshal(objects[intent], reserved) != nil {
						t.Error("release dispatched without readable durable intent")
					}
					if !proto.Equal(request, reserved) || !proto.Equal(posted, request.Release) {
						t.Error("dispatched request differs from reserved intent")
					}
					if r.URL.Query().Get("requestId") != request.RequestId || r.URL.Query().Get("releaseId") != request.ReleaseId {
						t.Error("native deduplication identity missing")
					}
					if testCase.failure == "create-denied" {
						http.Error(w, "private-provider-detail", http.StatusForbidden)
						return
					}
					native = proto.Clone(request.Release).(*deploypb.Release)
					native.RenderState, native.Uid = testCase.render, "server-owned-uid"
					if testCase.failure == "conflict" {
						native.DeployParameters["masterKeyVersion"] = "99"
					}
					native.Abandoned = testCase.failure == "abandoned"
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
				case r.Method == http.MethodGet && r.URL.Path == "/b/"+bucket+"/o/"+intent:
					if data, exists := objects[intent]; exists {
						_, _ = w.Write(data)
					} else {
						http.NotFound(w, r)
					}
				case r.Method == http.MethodGet && r.URL.Path == "/b/"+bucket+"/o/"+sourceName:
					if source == nil {
						http.NotFound(w, r)
					} else {
						_, _ = w.Write(source)
					}
				case r.Method == http.MethodGet && r.URL.Path == "/v1/"+request.Release.Name:
					if native != nil {
						_, _ = w.Write(wire(t, native))
					} else {
						http.NotFound(w, r)
					}
				default:
					t.Errorf("unexpected cloud operation: %s %s", r.Method, r.URL.Path)
					http.NotFound(w, r)
				}
			}))
			defer server.Close()
			options := []option.ClientOption{option.WithEndpoint(server.URL), option.WithoutAuthentication()}
			var publication bytes.Buffer
			require.Zero(t, submission.Run(ctx, arguments(t, "publish-release-source", path, sourceDirectory), &publication, &publication, options...), "%s", &publication)
			mutex.Lock()
			switch testCase.failure {
			case "source-missing":
				source = nil
			case "source-conflict":
				source = []byte("unexpected-source")
			}
			mutex.Unlock()
			attempts := 1
			if testCase.concurrent {
				attempts = 2
			}
			codes := make(chan int, attempts)
			for range cap(codes) {
				go func() {
					var output bytes.Buffer
					code := submission.Run(ctx, arguments(t, "submit-release", path, sourceDirectory), &output, &output, options...)
					if strings.Contains(output.String(), "private-provider-detail") {
						t.Error("provider detail leaked")
					}
					codes <- code
				}()
			}
			got := result{}
			for range cap(codes) {
				got.submit = append(got.submit, <-codes)
			}
			slices.Sort(got.submit)
			mutex.Lock()
			if testCase.failure == "stored-conflict" {
				conflict := proto.Clone(request).(*deploypb.CreateReleaseRequest)
				conflict.ReleaseId += "-other"
				conflict.Release.Name += "-other"
				objects[intent] = wire(t, conflict)
			}
			beforeWrites := writes
			mutex.Unlock()
			var output bytes.Buffer
			got.reconcile = submission.Run(t.Context(), arguments(t, "reconcile-release", request.ReleaseId), &output, &output, options...)
			mutex.Lock()
			got.creates, got.records = creates, len(objects)
			afterWrites := writes
			mutex.Unlock()
			require.Equal(t, beforeWrites, afterWrites, "reconciliation must never write")
			require.Equal(t, testCase.want, got, "reconcile output: %s", &output)
			if got.reconcile == 0 {
				require.Contains(t, output.String(), "This check does not establish deployment or durable success receipt completion.")
			}
		})
	}
}
