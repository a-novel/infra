package custody_test

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"mime"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
	"google.golang.org/api/option"
	"google.golang.org/api/storage/v1"

	"github.com/a-novel/infra/internal/custody"
)

func TestPermissions(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, invalid string
		step, status  int
		message       string
	}{
		{name: "Success"},
		{name: "Success/Authentication"},
		{name: "Success/AccessDenial"},
		{name: "Error/UnexpectedMetadata", step: 1, status: 200},
		{name: "Error/ReadMismatch", step: 2, status: 200},
		{name: "Error/StateCreate", step: 1, status: 403},
		{name: "Error/StateRead", step: 2, status: 404},
		{name: "Error/StateReplace", step: 3, status: 412},
		{name: "Error/ReplacementRead", step: 4, status: 404},
		{name: "Error/ReceiptCreate", step: 5, status: 503},
		{name: "Error/ReceiptRead", step: 6, status: 403},
		{name: "Error/OverwriteAllowed", step: 7, status: 200},
		{name: "Error/RetentionIsNotIAM", step: 7, status: 403, message: "object is subject to retention policy"},
		{name: "Error/OverwritePrecondition", step: 7, status: 412},
		{name: "Error/DeleteAllowed", step: 8, status: 204},
		{name: "Error/ReceiptChanged", step: 9, status: 404},
		{name: "Error/ReceiptGenerationChanged", step: 9, status: 200},
		{name: "Error/Cancelled", step: 10, status: 503},
		{name: "Error/PeerReadAllowed", step: 10, status: 200},
		{name: "Error/PeerMissing", step: 10, status: 404},
		{name: "Error/PeerUnauthenticated", step: 10, status: 401},
		{name: "Error/PeerUnrelatedDenial", step: 10, status: 403, message: "billing disabled"},
		{name: "Error/PeerWrongPermission", step: 10, status: 403, message: "Permission 'storage.objects.list' denied"},
		{name: "Error/PeerStateCreateAllowed", step: 11, status: 200},
		{name: "Error/PeerReceiptReadAllowed", step: 12, status: 200},
		{name: "Error/PeerReceiptCreateAllowed", step: 13, status: 200},
		{name: "Error/Cleanup", step: 14, status: 503},
		{name: "Error/CleanupSecondGeneration", step: 15, status: 412},
		{name: "Error/Ref", invalid: "GITHUB_REF"},
		{name: "Error/Event", invalid: "GITHUB_EVENT_NAME"},
		{name: "Error/Repository", invalid: "GITHUB_REPOSITORY"},
		{name: "Error/Workflow", invalid: "GITHUB_WORKFLOW_REF"},
		{name: "Error/Environment", invalid: "PERMISSION_CHECK_ENVIRONMENT"},
		{name: "Error/Action", invalid: "RELEASE_ACTION"},
		{name: "Error/Run", invalid: "GITHUB_RUN_ID"},
		{name: "Error/Attempt", invalid: "GITHUB_RUN_ATTEMPT"},
		{name: "Error/Commit", invalid: "GITHUB_SHA"},
		{name: "Error/Scope", invalid: "scope"},
		{name: "Error/Peer", invalid: "peer"},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			bucket := "agora-management-test-123-tofu-state"
			receipts := strings.TrimSuffix(bucket, "-tofu-state") + "-deployment-receipts"
			own := "workloads/production/private/agora-private-test/json-keys"
			peer := "workloads/production/public-api/agora-api-test/authentication"
			if testCase.name == "Success/Authentication" {
				own, peer = peer, own
			}
			parts := strings.Split(own, "/")
			env := map[string]string{
				"GITHUB_REPOSITORY": "a-novel/infra", "GITHUB_REF": "refs/heads/master",
				"GITHUB_EVENT_NAME": "workflow_dispatch", "RELEASE_ACTION": "check-release-permissions",
				"GITHUB_WORKFLOW_REF":          "a-novel/infra/.github/workflows/release.yaml@refs/heads/master",
				"PERMISSION_CHECK_ENVIRONMENT": "production-" + parts[4] + "-" + parts[2] + "-release",
				"GITHUB_SHA":                   strings.Repeat("a", 40), "GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "2",
			}
			probe := "/permission-checks/" + env["GITHUB_SHA"] + "/123-2/probe.json"
			type request struct {
				method, bucket, name, generation, match, permission string
			}
			requests := []request{
				{http.MethodPost, bucket, own + "/release" + probe, "", "0", ""},
				{http.MethodGet, bucket, own + "/release" + probe, "41", "", ""},
				{http.MethodPost, bucket, own + "/release" + probe, "", "41", ""},
				{http.MethodGet, bucket, own + "/release" + probe, "42", "", ""},
				{http.MethodPost, receipts, own + "/production" + probe, "", "0", ""},
				{http.MethodGet, receipts, own + "/production" + probe, "43", "", ""},
				{http.MethodPost, receipts, own + "/production" + probe, "", "43", "storage.objects.delete"},
				{http.MethodDelete, receipts, own + "/production" + probe, "43", "43", "storage.objects.delete"},
				{http.MethodGet, receipts, own + "/production" + probe, "", "", ""},
				{http.MethodGet, bucket, peer + "/release" + probe, "", "", "storage.objects.get"},
				{http.MethodPost, bucket, peer + "/release" + probe, "", "0", "storage.objects.create"},
				{http.MethodGet, receipts, peer + "/production" + probe, "", "", "storage.objects.get"},
				{http.MethodPost, receipts, peer + "/production" + probe, "", "0", "storage.objects.create"},
				{http.MethodDelete, bucket, own + "/release" + probe, "41", "41", ""},
				{http.MethodDelete, bucket, own + "/release" + probe, "42", "42", ""},
			}
			var seen []int
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				step := len(seen) + 1
				if r.Method == http.MethodDelete && strings.Contains(r.URL.Path, bucket+"/o/") {
					step = 14
					if r.URL.Query().Get("generation") == "42" {
						step = 15
					}
				}
				seen = append(seen, step)
				if step > len(requests) {
					t.Error("unexpected request after completion")
					w.WriteHeader(500)
					return
				}
				expected := requests[step-1]
				path := "/b/" + expected.bucket + "/o/" + expected.name
				if r.Method == http.MethodPost {
					path = "/upload/storage/v1/b/" + expected.bucket + "/o"
					_, params, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
					if err != nil {
						panic(err)
					}
					reader := multipart.NewReader(r.Body, params["boundary"])
					metadata, err := reader.NextPart()
					if err != nil {
						panic(err)
					}
					var object storage.Object
					if err := json.NewDecoder(metadata).Decode(&object); err != nil {
						panic(err)
					}
					media, err := reader.NextPart()
					if err != nil {
						panic(err)
					}
					data, err := io.ReadAll(media)
					if err != nil {
						panic(err)
					}
					if object.Name != expected.name || string(data) != `{"kind":"synthetic-permission-check"}` {
						t.Error("write escaped the exact synthetic object")
					}
				}
				if r.Method != expected.method || r.URL.Path != path || r.URL.Query().Get("ifGenerationMatch") != expected.match || r.URL.Query().Get("generation") != expected.generation {
					t.Errorf("step %d: unexpected request %s %s", step, r.Method, r.URL)
				}
				if strings.Contains(expected.name, peer) && r.Method == http.MethodGet && (r.URL.Query().Get("fields") != "generation" || r.URL.Query().Get("alt") == "media") {
					t.Error("peer reads must never request stored payloads")
				}
				status, message := 200, "private-value"
				if expected.permission != "" {
					status, message = 403, "Permission '"+expected.permission+"' denied; private-value"
					if testCase.name == "Success/AccessDenial" {
						message = "identity does not have " + expected.permission + " access; private-value"
					}
				}
				if step == testCase.step {
					status, message = testCase.status, testCase.message+" private-value"
					if testCase.name == "Error/Cancelled" {
						cancel()
					}
				}
				w.Header().Set("Content-Type", "application/json")
				if status >= 400 {
					w.WriteHeader(status)
					_ = json.NewEncoder(w).Encode(map[string]any{"error": map[string]any{"code": status, "message": message}})
					return
				}
				if r.Method == http.MethodDelete {
					w.WriteHeader(http.StatusNoContent)
					return
				}
				if r.URL.Query().Get("alt") == "media" {
					data := `{"kind":"synthetic-permission-check"}`
					if testCase.name == "Error/ReadMismatch" {
						data = "private-value"
					}
					_, _ = io.WriteString(w, data)
					return
				}
				generation := int64(43)
				switch step {
				case 1:
					generation = 41
				case 3:
					generation = 42
				}
				if testCase.name == "Error/UnexpectedMetadata" {
					expected.name = "private-value"
				}
				if step == 9 && testCase.name == "Error/ReceiptGenerationChanged" {
					generation = 44
				}
				_ = json.NewEncoder(w).Encode(&storage.Object{Bucket: expected.bucket, Name: expected.name, Generation: generation})
			}))
			defer server.Close()
			if testCase.invalid == "scope" {
				own += "/../default.tfstate"
			} else if testCase.invalid == "peer" {
				peer = own
			} else if testCase.invalid != "" {
				env[testCase.invalid] = "unexpected"
			}
			var output bytes.Buffer
			code := custody.Run(ctx, []string{"permissions", "check", bucket, own, peer}, func(key string) string { return env[key] }, nil, &output, &output,
				option.WithEndpoint(server.URL+"/"), option.WithHTTPClient(server.Client()), option.WithoutAuthentication())
			require.NotContains(t, output.String(), "private-value")
			if strings.HasPrefix(testCase.name, "Success") {
				require.Equal(t, 0, code, output.String())
				require.Len(t, seen, 15)
			} else {
				require.NotZero(t, code, output.String())
				require.NotContains(t, output.String(), "operation completed")
			}
			if testCase.invalid != "" {
				require.Empty(t, seen)
			} else if testCase.step == 1 {
				require.Equal(t, []int{1}, seen)
			} else {
				expected := []int{}
				last := 13
				if testCase.step > 0 && testCase.step < 14 {
					last = testCase.step
				}
				for step := 1; step <= last; step++ {
					expected = append(expected, step)
				}
				expected = append(expected, 14)
				if testCase.step == 0 || testCase.step > 3 {
					expected = append(expected, 15)
				}
				require.Equal(t, expected, seen, "failure step %d", testCase.step)
			}
		})
	}
}
