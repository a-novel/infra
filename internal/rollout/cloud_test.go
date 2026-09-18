package rollout_test

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"cloud.google.com/go/longrunning/autogen/longrunningpb"
	"cloud.google.com/go/run/apiv2/runpb"
	"github.com/stretchr/testify/require"
	"google.golang.org/api/option"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/anypb"
	"google.golang.org/protobuf/types/known/timestamppb"

	"github.com/a-novel/infra/internal/rollout"
)

func TestVerify(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name                                string
		dispatchFailure, interrupt, changed bool
	}{
		{name: "Success"},
		{name: "Error/AmbiguousInvocation", dispatchFailure: true},
		{name: "Error/InterruptedWait", interrupt: true},
		{name: "Error/TrafficChangedAfterProbe", changed: true},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			config, state, job := fixture(t)
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			var dispatches atomic.Int32
			server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
				writer.Header().Set("Content-Type", "application/json")
				name := strings.TrimPrefix(strings.TrimPrefix(request.URL.Path, "/v1/"), "/v2/")
				if request.Method == http.MethodPost && name == job.Name+":run" {
					dispatches.Add(1)
					if testCase.dispatchFailure {
						http.Error(writer, "private provider detail", http.StatusBadGateway)
						return
					}
					body, err := io.ReadAll(request.Body)
					if err != nil {
						t.Error(err)
						return
					}
					input := &runpb.RunJobRequest{}
					if err := protojson.Unmarshal(body, input); err != nil {
						t.Error(err)
						return
					}
					if input.GetEtag() != job.Etag || len(input.GetOverrides().GetContainerOverrides()) != 1 {
						t.Error("unexpected execution request")
						return
					}
					template := proto.Clone(job.Template.Template).(*runpb.TaskTemplate)
					template.Containers[0].Env = input.Overrides.ContainerOverrides[0].Env
					execution := &runpb.Execution{
						Name: job.Name + "/executions/probe-1", Job: job.Name, TaskCount: 1, SucceededCount: 1,
						CompletionTime: timestamppb.Now(), Template: template,
					}
					result, err := anypb.New(execution)
					if err != nil {
						t.Error(err)
						return
					}
					operation := &longrunningpb.Operation{
						Name: "projects/123456/locations/europe-west1/operations/probe-1", Done: !testCase.interrupt,
						Result: &longrunningpb.Operation_Response{Response: result},
					}
					data, err := protojson.Marshal(operation)
					if err != nil {
						t.Error(err)
						return
					}
					_, _ = writer.Write(data)
					return
				}
				if strings.Contains(name, "/operations/") && testCase.interrupt {
					cancel()
					return
				}
				responses := map[string]proto.Message{
					state.Release.Name: state.Release, state.Rollout.Name: state.Rollout,
					state.JobRun.Name: state.JobRun, state.Service.Name: state.Service, state.Revision.Name: state.Revision, job.Name: job,
				}
				response := responses[name]
				if response == nil || request.Method != http.MethodGet {
					t.Errorf("unexpected API request: %s %s", request.Method, name)
					http.NotFound(writer, request)
					return
				}
				if testCase.changed && dispatches.Load() > 0 && name == state.Service.Name {
					service := proto.Clone(state.Service).(*runpb.Service)
					service.TrafficStatuses[1].Revision = "other"
					response = service
				}
				data, err := protojson.Marshal(response)
				if err != nil {
					t.Error(err)
					return
				}
				_, _ = writer.Write(data)
			}))
			defer server.Close()
			var output bytes.Buffer
			err := rollout.Verify(ctx, config, &output, option.WithEndpoint(server.URL), option.WithoutAuthentication())
			require.EqualValues(t, 1, dispatches.Load(), "an uncertain dispatch must not start a second execution")
			if testCase.name == "Success" {
				require.NoError(t, err)
				require.Contains(t, output.String(), "execution="+job.Name+"/executions/probe-1")
			} else {
				require.Error(t, err)
				require.NotContains(t, err.Error(), "private provider detail")
				require.NotContains(t, output.String(), "PASS")
			}
		})
	}
}
