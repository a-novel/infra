package submission_test

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
	"google.golang.org/api/option"

	"github.com/a-novel/infra/internal/submission"
)

func TestRun(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, document, project string
	}{
		{"UnknownField", `{"private-input":"must-not-be-logged"}`, "agora-json-keys-test"},
		{"MalformedJSON", `{"private-input":`, "agora-json-keys-test"},
		{"BoundedInput", strings.Repeat(" ", 64<<10) + "{}", "agora-json-keys-test"},
		{"ScopeInjection", "{}", "../../peer"},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			path := filepath.Join(t.TempDir(), "request.json")
			require.NoError(t, os.WriteFile(path, []byte(testCase.document), 0o600))
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				t.Error("invalid input reached a cloud client")
				w.WriteHeader(http.StatusForbidden)
			}))
			defer server.Close()
			args := arguments(t, "publish-release-source", path)
			args[1] = "--project-id=" + testCase.project
			var output bytes.Buffer
			code := submission.Run(t.Context(), args, &output, &output, option.WithEndpoint(server.URL), option.WithoutAuthentication())
			require.Equal(t, 1, code)
			require.NotContains(t, output.String(), "private-input")
		})
	}
}

func TestSubmissionArguments(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, command, argument string
	}{
		{"NoStandaloneRelease", "submit-release", ""},
		{"NoStandaloneRollout", "submit-rollout", "--request-id=22222222-2222-4222-8222-222222222222"},
		{"NoStandaloneMigration", "submit-migration", "--job-uid=11111111-1111-4111-8111-111111111111"},
		{"ReconcileHasNoUUID", "reconcile-rollout", "--request-id=22222222-2222-4222-8222-222222222222"},
		{"NoReconcileJobOverride", "reconcile-migration", "--job-uid=private-input"},
		{"NoReconcileImageOverride", "reconcile-migration", "--image=private-input"},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				t.Error("invalid submission arguments reached a cloud client")
				w.WriteHeader(http.StatusForbidden)
			}))
			defer server.Close()
			args := arguments(t, testCase.command, testCase.argument)
			if testCase.argument == "" {
				args[len(args)-1] = "release-1"
			} else {
				args = append(args, "release-1")
			}
			var output bytes.Buffer
			code := submission.Run(t.Context(), args, &output, &output, option.WithEndpoint(server.URL), option.WithoutAuthentication())
			require.Equal(t, 1, code)
			require.NotContains(t, output.String(), "private-input")
		})
	}
}
