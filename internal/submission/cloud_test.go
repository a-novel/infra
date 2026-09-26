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

func TestReconcileRelease(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name string
		want int
	}{
		{"Rendered", 0},
		{"RenderingIsNotDeployment", 0},
		{"IntentMissing", 1},
		{"NativeMissing", 1},
		{"ReadDenied", 1},
		{"NativeConflict", 1},
		{"StoredIdentityConflict", 1},
		{"RenderFailed", 1},
		{"UnknownRender", 1},
		{"Abandoned", 1},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			request := fixture(t)
			native := proto.Clone(request.Release).(*deploypb.Release)
			native.Uid, native.RenderState = "release-uid", deploypb.Release_SUCCEEDED
			switch testCase.name {
			case "RenderingIsNotDeployment":
				native.RenderState = deploypb.Release_IN_PROGRESS
			case "NativeConflict":
				native.DeployParameters["masterKeyVersion"] = "99"
			case "StoredIdentityConflict":
				request.ReleaseId += "-other"
				request.Release.Name += "-other"
			case "RenderFailed":
				native.RenderState = deploypb.Release_FAILED
			case "UnknownRender":
				native.RenderState = deploypb.Release_RENDER_STATE_UNSPECIFIED
			case "Abandoned":
				native.Abandoned = true
			}
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				if r.Method != http.MethodGet {
					t.Error("reconciliation attempted a write")
					w.WriteHeader(http.StatusForbidden)
					return
				}
				switch r.URL.Path {
				case "/b/" + bucket + "/o/" + intent:
					if testCase.name == "IntentMissing" {
						http.NotFound(w, r)
					} else {
						_, _ = w.Write(wire(t, request))
					}
				case "/v1/" + native.Name:
					switch testCase.name {
					case "NativeMissing":
						http.NotFound(w, r)
					case "ReadDenied":
						http.Error(w, "private-provider-detail", http.StatusForbidden)
					default:
						_, _ = w.Write(wire(t, native))
					}
				default:
					t.Errorf("unexpected read %s", r.URL.Path)
					w.WriteHeader(http.StatusForbidden)
				}
			}))
			defer server.Close()
			var output bytes.Buffer
			code := submission.Run(t.Context(), arguments(t, "reconcile-release", "release-1"), &output, &output,
				option.WithEndpoint(server.URL), option.WithoutAuthentication())
			require.Equal(t, testCase.want, code, "%s", &output)
			require.NotContains(t, output.String(), "private-provider-detail")
			require.Equal(t, code == 0, strings.Contains(output.String(), "This check does not establish deployment or durable success receipt completion."))
		})
	}
}
