package submission_test

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"cloud.google.com/go/deploy/apiv1/deploypb"
	"github.com/stretchr/testify/require"
	"google.golang.org/api/option"
	"google.golang.org/protobuf/proto"

	"github.com/a-novel/infra/internal/submission"
)

func TestReconcileRollout(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name string
		want int
	}{
		{"Succeeded", 0},
		{"PendingApproval", 1},
		{"FailedVerification", 1},
		{"IntentMissing", 1},
		{"NativeMissing", 1},
		{"NativeConflict", 1},
		{"StoredPolicyOverride", 1},
		{"StoredUnknownField", 1},
		{"RecreatedRelease", 1},
		{"UUIDReused", 1},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			request := fixture(t)
			release := proto.Clone(request.Release).(*deploypb.Release)
			release.Uid, release.RenderState = "release-uid", deploypb.Release_SUCCEEDED
			native := operationRollout(t, release)
			rolloutIntent := strings.TrimSuffix(intent, ".json") + ".rollout.json"
			reserved := &deploypb.CreateRolloutRequest{
				Parent: release.Name, RolloutId: "production", StartingPhaseId: "canary-0",
				RequestId: native.Annotations["request-id"],
				Rollout:   &deploypb.Rollout{Name: native.Name, TargetId: native.TargetId, Annotations: native.Annotations},
			}
			switch testCase.name {
			case "PendingApproval":
				native.State, native.ApprovalState = deploypb.Rollout_PENDING_APPROVAL, deploypb.Rollout_NEEDS_APPROVAL
			case "FailedVerification":
				native.Phases[1].GetDeploymentJobs().VerifyJob.State = deploypb.Job_FAILED
			case "StoredPolicyOverride":
				reserved.StartingPhaseId = "stable"
			case "RecreatedRelease":
				release.Uid = "recreated"
			case "UUIDReused":
				reserved.RequestId = request.RequestId
			}
			objects := map[string][]byte{intent: wire(t, request), rolloutIntent: wire(t, reserved)}
			switch testCase.name {
			case "IntentMissing":
				delete(objects, rolloutIntent)
			case "StoredUnknownField":
				objects[rolloutIntent] = []byte(`{"private-input":true}`)
			case "NativeConflict":
				native.Annotations["release-uid"] = "peer"
			}
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				if r.Method != http.MethodGet {
					t.Error("rollout reconciliation attempted a write")
					w.WriteHeader(http.StatusForbidden)
					return
				}
				switch {
				case strings.HasPrefix(r.URL.Path, "/b/"+bucket+"/o/"):
					data, exists := objects[strings.TrimPrefix(r.URL.Path, "/b/"+bucket+"/o/")]
					if !exists {
						http.NotFound(w, r)
					} else {
						_, _ = w.Write(data)
					}
				case r.URL.Path == "/v1/"+release.Name:
					_, _ = w.Write(wire(t, release))
				case r.URL.Path == "/v1/"+native.Name:
					if testCase.name == "NativeMissing" {
						http.NotFound(w, r)
					} else {
						_, _ = w.Write(wire(t, native))
					}
				default:
					t.Errorf("unexpected read %s", r.URL.Path)
					w.WriteHeader(http.StatusForbidden)
				}
			}))
			defer server.Close()
			var output bytes.Buffer
			code := submission.Run(t.Context(), arguments(t, "reconcile-rollout", request.ReleaseId), &output, &output,
				option.WithEndpoint(server.URL), option.WithoutAuthentication())
			require.Equal(t, testCase.want, code, "%s", &output)
			require.NotContains(t, output.String(), "private-input")
		})
	}
}
