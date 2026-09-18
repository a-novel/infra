package rollout_test

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"cloud.google.com/go/deploy/apiv1/deploypb"
	"github.com/stretchr/testify/require"
	"google.golang.org/api/option"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"

	"github.com/a-novel/infra/internal/rollout"
)

func TestRunObserver(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name string
		mode string
		code int
		want string
	}{
		{"Success", "success", 0, "succeeded: candidate and stable deployment/verification"},
		{"Error/Verification", "verify", 70, "failed: stable/verify"},
		{"Action/Approval", "approval", 70, "action-required: approval"},
		{"Error/API", "api", 70, "interrupted: release status unavailable"},
		{"Error/Cancelled", "cancel", 70, "interrupted: observation timeout or cancellation"},
		{"Error/Deadline", "deadline", 70, "interrupted: observation timeout or cancellation"},
		{"Error/QueuedDeadline", "queued", 70, "interrupted: observation timeout or cancellation"},
		{"Error/MissingName", "missing", 64, ""},
		{"Error/NameInjection", "invalid", 70, ""},
		{"Error/UnboundedTimeout", "unbounded", 70, ""},
		{"Error/ZeroTimeout", "zero", 70, ""},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			_, state, _ := fixture(t)
			completeRollout(t, state.Rollout)
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			switch testCase.mode {
			case "verify":
				state.Rollout.State = deploypb.Rollout_FAILED
				state.Rollout.Phases[1].GetDeploymentJobs().VerifyJob.State = deploypb.Job_FAILED
			case "approval":
				state.Rollout.ApprovalState = deploypb.Rollout_NEEDS_APPROVAL
			case "queued":
				state.Rollout.State = deploypb.Rollout_PENDING
			}
			server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
				if request.Method != http.MethodGet {
					t.Error("observation attempted a mutation")
				}
				if testCase.mode == "api" {
					http.Error(writer, "private-provider-detail", http.StatusForbidden)
					return
				}
				if testCase.mode == "cancel" {
					cancel()
				}
				if testCase.mode == "deadline" {
					<-request.Context().Done()
					return
				}
				var response proto.Message
				switch request.URL.Path {
				case "/v1/" + state.Release.Name:
					response = state.Release
				case "/v1/" + state.Rollout.Name:
					response = state.Rollout
				default:
					t.Errorf("unexpected API path: %s", request.URL.Path)
					http.NotFound(writer, request)
					return
				}
				data, err := protojson.Marshal(response)
				if err != nil {
					t.Error(err)
					return
				}
				writer.Header().Set("Content-Type", "application/json")
				_, _ = writer.Write(data)
			}))
			defer server.Close()
			summary := filepath.Join(t.TempDir(), "summary.md")
			args := []string{"--timeout=1s", "--summary=" + summary, state.Rollout.Name}
			switch testCase.mode {
			case "missing":
				args = args[:2]
			case "invalid":
				args[2] += "\n::error::injected"
			case "unbounded":
				args[0] = "--timeout=1h"
			case "zero":
				args[0] = "--timeout=0"
			}
			var output, errors bytes.Buffer
			code := rollout.RunObserver(ctx, args, &output, &errors, option.WithEndpoint(server.URL), option.WithoutAuthentication())
			data, err := os.ReadFile(summary)
			if testCase.mode == "missing" {
				require.ErrorIs(t, err, os.ErrNotExist)
			} else {
				require.NoError(t, err)
			}
			result := struct {
				code                          int
				verdict, summaryMatches, safe bool
			}{
				code, strings.Contains(output.String(), testCase.want), string(data) == output.String(),
				!strings.Contains(output.String()+errors.String(), "private-provider-detail"),
			}
			require.Equal(t, struct {
				code                          int
				verdict, summaryMatches, safe bool
			}{testCase.code, true, true, true}, result, "stdout: %s\nstderr: %s", &output, &errors)
		})
	}
}
