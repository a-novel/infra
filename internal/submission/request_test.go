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
	sourceDirectory := sourceCheckout(t)
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
			bindSource(t, request, sourceDirectory)
			testCase.change(request)
			path := filepath.Join(t.TempDir(), "request.json")
			require.NoError(t, os.WriteFile(path, wire(t, request), 0o600))
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				t.Error("invalid request reached a cloud client")
				w.WriteHeader(http.StatusForbidden)
			}))
			defer server.Close()
			var output bytes.Buffer
			code := submission.Run(t.Context(), arguments(t, "publish-release-source", path, sourceDirectory), &output, &output,
				option.WithEndpoint(server.URL), option.WithoutAuthentication())
			require.Equal(t, 1, code)
			require.NotContains(t, output.String(), "private-input")
		})
	}
}

func TestSharedRequest(t *testing.T) {
	t.Parallel()
	directory := sourceCheckout(t, "json-keys", "json-keys-rest", "authentication-rest")
	for _, component := range []struct {
		service, zone string
		waitlist      bool
	}{
		{"json-keys", "private", false},
		{"json-keys", "public-api", false},
		{"authentication", "public-api", false},
		{"authentication", "public-api", true},
	} {
		name := component.service + "/" + component.zone
		if component.waitlist {
			name += "/Waitlist"
		}
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			for _, testCase := range []struct {
				name   string
				change func(*deploypb.CreateReleaseRequest)
			}{
				{"Success", func(_ *deploypb.CreateReleaseRequest) {}},
				{"Error/PeerPipeline", func(r *deploypb.CreateReleaseRequest) { r.Parent += "-peer" }},
				{"Error/PeerRuntimeInSameProject", func(r *deploypb.CreateReleaseRequest) {
					r.Release.DeployParameters["runtimeServiceAccount"] = "agora-peer-api@agora-public-api-test.iam.gserviceaccount.com"
				}},
				{"Error/PeerCustody", func(r *deploypb.CreateReleaseRequest) {
					r.Release.SkaffoldConfigUri = strings.ReplaceAll(r.Release.SkaffoldConfigUri, "/"+component.service+"/", "/peer/")
				}},
				{"Error/PeerRepository", func(r *deploypb.CreateReleaseRequest) {
					r.Release.BuildArtifacts[0].Tag = strings.Replace(r.Release.BuildArtifacts[0].Tag, "/agora-"+component.service+"-", "/agora-peer-", 1)
				}},
				{"Error/WrongArtifactRole", func(r *deploypb.CreateReleaseRequest) {
					r.Release.BuildArtifacts[0].Tag = strings.Replace(r.Release.BuildArtifacts[0].Tag, "@sha256:", "/migrations@sha256:", 1)
				}},
				{"Error/PeerImageAlias", func(r *deploypb.CreateReleaseRequest) { r.Release.BuildArtifacts[0].Image += "-peer" }},
				{"Error/CallerSourcePath", func(r *deploypb.CreateReleaseRequest) { r.Release.SkaffoldConfigPath = "../skaffold.yaml" }},
				{"Error/MissingParameter", func(r *deploypb.CreateReleaseRequest) { delete(r.Release.DeployParameters, "postgresPasswordVersion") }},
				{"Error/LatestSecret", func(r *deploypb.CreateReleaseRequest) {
					r.Release.DeployParameters["postgresPasswordVersion"] = "latest"
				}},
				{"Error/PublicDatabase", func(r *deploypb.CreateReleaseRequest) { r.Release.DeployParameters["databasePrivateIP"] = "8.8.8.8" }},
				{"Error/ExtraCredential", func(r *deploypb.CreateReleaseRequest) {
					r.Release.DeployParameters["masterKeyPayload"] = "private-input"
				}},
				{"Error/OversizedParameter", func(r *deploypb.CreateReleaseRequest) {
					r.Release.DeployParameters["postgresPasswordVersion"] = strings.Repeat("1", 513)
				}},
			} {
				t.Run(testCase.name, func(t *testing.T) {
					t.Parallel()
					request, args := sharedFixture(t, directory, component.service, component.zone, component.waitlist)
					testCase.change(request)
					file := filepath.Join(t.TempDir(), "request.json")
					require.NoError(t, os.WriteFile(file, wire(t, request), 0o600))
					args = append([]string{"validate-release-source"}, args...)
					args = append(args, "--source-dir="+directory, file)
					server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
						t.Error("offline validation reached a cloud client")
						w.WriteHeader(http.StatusForbidden)
					}))
					defer server.Close()
					var output bytes.Buffer
					code := submission.Run(t.Context(), args, &output, &output, option.WithEndpoint(server.URL), option.WithoutAuthentication())
					if testCase.name == "Success" {
						require.Zero(t, code, output.String())
						require.Contains(t, output.String(), "no cloud client initialized")
					} else {
						require.Equal(t, 1, code, output.String())
					}
					require.NotContains(t, output.String(), "private-input")
				})
			}
		})
	}
}

func TestSharedRequestBoundary(t *testing.T) {
	t.Parallel()
	directory := sourceCheckout(t, "json-keys-rest", "authentication-rest")
	for _, testCase := range []struct {
		name, service, zone, command string
		waitlist                     bool
		change                       func(*deploypb.CreateReleaseRequest)
	}{
		{"Platform", "json-keys", "public", "validate-release-source", false, nil},
		{"PrivateAuthenticationAPI", "authentication", "private", "validate-release-source", false, nil},
		{"MissingZone", "json-keys", "", "validate-release-source", false, nil},
		{"MissingService", "", "public-api", "validate-release-source", false, nil},
		{"MigrationNotEnrolled", "json-keys", "public-api", "reconcile-migration", false, nil},
		{"RolloutNotEnrolled", "json-keys", "public-api", "reconcile-rollout", false, nil},
		{"PublicMasterKey", "json-keys", "public-api", "validate-release-source", false, func(r *deploypb.CreateReleaseRequest) { r.Release.DeployParameters["masterKeyVersion"] = "29" }},
		{"WaitlistMissingURL", "authentication", "public-api", "validate-release-source", true, func(r *deploypb.CreateReleaseRequest) { delete(r.Release.DeployParameters, "waitlistURL") }},
		{"WaitlistMissingSecret", "authentication", "public-api", "validate-release-source", true, func(r *deploypb.CreateReleaseRequest) { delete(r.Release.DeployParameters, "waitlistSecretVersion") }},
		{"WaitlistWrongManifest", "authentication", "public-api", "validate-release-source", true, func(r *deploypb.CreateReleaseRequest) { r.Release.SkaffoldConfigPath = "skaffold.yaml" }},
		{"UnrequestedWaitlist", "authentication", "public-api", "validate-release-source", false, func(r *deploypb.CreateReleaseRequest) { r.Release.SkaffoldConfigPath = "skaffold-waitlist.yaml" }},
		{"InsecureWaitlist", "authentication", "public-api", "validate-release-source", true, func(r *deploypb.CreateReleaseRequest) {
			r.Release.DeployParameters["waitlistURL"] = "http://example.test"
		}},
		{"WrongJSONKeysEndpoint", "authentication", "public-api", "validate-release-source", false, func(r *deploypb.CreateReleaseRequest) {
			r.Release.DeployParameters["jsonKeysHost"] = "agora-peer-123456.europe-west1.run.app"
		}},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			service, zone := testCase.service, testCase.zone
			switch service + "/" + zone {
			case "json-keys/public-api", "authentication/public-api":
			default:
				service, zone = "json-keys", "public-api"
			}
			request, args := sharedFixture(t, directory, service, zone, testCase.waitlist)
			args = append(args, "--service="+testCase.service, "--zone="+testCase.zone)
			if testCase.change != nil {
				testCase.change(request)
			}
			file := filepath.Join(t.TempDir(), "request.json")
			require.NoError(t, os.WriteFile(file, wire(t, request), 0o600))
			args = append([]string{testCase.command}, args...)
			if testCase.command == "validate-release-source" {
				args = append(args, "--source-dir="+directory)
			}
			args = append(args, file)
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				t.Error("unsupported shared boundary reached a cloud client")
				w.WriteHeader(http.StatusForbidden)
			}))
			defer server.Close()
			var output bytes.Buffer
			require.Equal(t, 1, submission.Run(t.Context(), args, &output, &output, option.WithEndpoint(server.URL), option.WithoutAuthentication()), output.String())
		})
	}
}
