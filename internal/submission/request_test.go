package submission_test

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"cloud.google.com/go/deploy/apiv1/deploypb"
	"github.com/stretchr/testify/require"
	"google.golang.org/api/option"

	"github.com/a-novel/infra/internal/submission"
)

func TestRequest(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name   string
		change func(*deploypb.CreateReleaseRequest)
	}{
		{"PeerPipeline", func(r *deploypb.CreateReleaseRequest) { r.Parent += "-peer" }},
		{"DifferentName", func(r *deploypb.CreateReleaseRequest) { r.Release.Name += "-other" }},
		{"NoRequestID", func(r *deploypb.CreateReleaseRequest) { r.RequestId = "" }},
		{"ZeroRequestID", func(r *deploypb.CreateReleaseRequest) { r.RequestId = "00000000-0000-0000-0000-000000000000" }},
		{"OverridePolicy", func(r *deploypb.CreateReleaseRequest) { r.OverrideDeployPolicy = []string{"unsafe"} }},
		{"ValidateOnly", func(r *deploypb.CreateReleaseRequest) { r.ValidateOnly = true }},
		{"OutputField", func(r *deploypb.CreateReleaseRequest) { r.Release.RenderState = deploypb.Release_SUCCEEDED }},
		{"MissingRelease", func(r *deploypb.CreateReleaseRequest) { r.Release = nil }},
		{"ExtraAnnotation", func(r *deploypb.CreateReleaseRequest) { r.Release.Annotations["private"] = "private-input" }},
		{"DifferentRequestID", func(r *deploypb.CreateReleaseRequest) { r.Release.Annotations["request-id"] = "other" }},
		{"UnpinnedSource", func(r *deploypb.CreateReleaseRequest) { r.Release.SkaffoldConfigUri += "-latest" }},
		{"UnpinnedSkaffold", func(r *deploypb.CreateReleaseRequest) { r.Release.SkaffoldVersion = "latest" }},
		{"ExtraImage", func(r *deploypb.CreateReleaseRequest) {
			r.Release.BuildArtifacts = append(r.Release.BuildArtifacts, r.Release.BuildArtifacts[0])
		}},
		{"PeerImage", func(r *deploypb.CreateReleaseRequest) {
			r.Release.BuildArtifacts[0].Tag = strings.ReplaceAll(r.Release.BuildArtifacts[0].Tag, "agora-json-keys-test", "agora-other-test")
		}},
		{"MissingDigest", func(r *deploypb.CreateReleaseRequest) { r.Release.BuildArtifacts[0].Tag += "x" }},
		{"ExtraParameter", func(r *deploypb.CreateReleaseRequest) { r.Release.DeployParameters["private"] = "private-input" }},
		{"PeerSubnet", func(r *deploypb.CreateReleaseRequest) {
			r.Release.DeployParameters["subnetwork"] = "projects/other-host-test/regions/europe-west1/subnetworks/agora-production"
		}},
		{"PeerAccount", func(r *deploypb.CreateReleaseRequest) {
			r.Release.DeployParameters["runtimeServiceAccount"] = "agora-json-keys@other-project.iam.gserviceaccount.com"
		}},
		{"PublicDatabase", func(r *deploypb.CreateReleaseRequest) { r.Release.DeployParameters["databasePrivateIP"] = "8.8.8.8" }},
		{"LatestSecret", func(r *deploypb.CreateReleaseRequest) { r.Release.DeployParameters["masterKeyVersion"] = "latest" }},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			request := fixture(t)
			testCase.change(request)
			path := filepath.Join(t.TempDir(), "request.json")
			require.NoError(t, os.WriteFile(path, wire(t, request), 0o600))
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				t.Error("invalid request reached a cloud client")
				w.WriteHeader(http.StatusForbidden)
			}))
			defer server.Close()
			var output bytes.Buffer
			code := submission.Run(t.Context(), arguments(t, "submit-release", path), &output, &output,
				option.WithEndpoint(server.URL), option.WithoutAuthentication())
			require.Equal(t, 1, code)
			require.NotContains(t, output.String(), "private-input")
		})
	}
}
