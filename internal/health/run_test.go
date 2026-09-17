package health_test

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/a-novel/infra/internal/health"
)

const healthy = `{"api:jsonKeys":{"status":"up"},"client:postgres":{"status":"up"},"client:smtp":{"status":"up"}}`

func TestRun(t *testing.T) {
	t.Parallel()
	down := strings.Replace(healthy, `"up"`, `"down"`, 1)
	for _, testCase := range []struct {
		name, mode, body       string
		status, requests, code int
		recover                bool
	}{
		{"Healthy", "candidate", healthy, 200, 1, 0, false},
		{"Deployed", "deployed", healthy, 200, 1, 0, false},
		{"DownThenHealthy", "candidate", down, 503, 2, 0, true},
		{"DownWith200ThenHealthy", "candidate", down, 200, 2, 0, true},
		{"Exhausted", "candidate", down, 503, 3, 70, false},
		{"ScheduledDoesNotRetry", "deployed", down, 503, 1, 70, false},
		{"PostgresDown", "deployed", strings.Replace(healthy, `"client:postgres":{"status":"up"}`, `"client:postgres":{"status":"down"}`, 1), 200, 1, 70, false},
		{"SMTPDown", "deployed", strings.Replace(healthy, `"client:smtp":{"status":"up"}`, `"client:smtp":{"status":"down"}`, 1), 200, 1, 70, false},
		{"Forbidden", "candidate", "private-payload", 403, 1, 70, false},
		{"Redirect", "candidate", healthy, 302, 1, 70, false},
		{"Healthy503", "candidate", healthy, 503, 1, 70, false},
		{"Malformed", "candidate", "private-payload", 200, 1, 70, false},
		{"MissingDependencies", "candidate", `{}`, 200, 1, 70, false},
		{"UnknownStatus", "candidate", strings.Replace(healthy, "up", "private-payload", 1), 200, 1, 70, false},
		{"ExtraField", "candidate", strings.Replace(healthy, `"up"`, `"up","detail":"private-payload"`, 1), 200, 1, 70, false},
		{"ExtraDependency", "candidate", strings.TrimSuffix(healthy, "}") + `,"private-payload":{"status":"up"}}`, 200, 1, 70, false},
		{"TwoDocuments", "candidate", healthy + healthy, 200, 1, 70, false},
		{"TooLarge", "candidate", healthy + strings.Repeat(" ", 4096), 200, 1, 70, false},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			var calls atomic.Int32
			server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				call := calls.Add(1)
				if r.Method != http.MethodGet || r.URL.Path != "/v2/healthcheck" || r.Header.Get("Accept") != "application/json" {
					w.WriteHeader(http.StatusBadRequest)
					return
				}
				body, status := testCase.body, testCase.status
				if call > 1 && testCase.recover {
					body, status = healthy, 200
				}
				w.Header().Set("Location", "/redirected")
				w.WriteHeader(status)
				_, _ = io.WriteString(w, body)
			}))
			t.Cleanup(server.Close)
			transport := server.Client().Transport.(*http.Transport)
			transport.TLSClientConfig.ServerName = server.Certificate().DNSNames[0]
			transport.DialContext = func(ctx context.Context, network, _ string) (net.Conn, error) {
				return (&net.Dialer{}).DialContext(ctx, network, server.Listener.Addr().String())
			}
			args := []string{testCase.mode, "https://fixture.run.app"}
			cloudCalls := 0
			execute := func(_ context.Context, output io.Writer, name string, args ...string) error {
				cloudCalls++
				require.Equal(t, "gcloud", name)
				require.Equal(t, []string{"run", "services", "describe", "agora-authentication-rest", "--project=fixture-project", "--region=europe-west1", "--format=value(status.url)", "--quiet"}, args)
				_, err := fmt.Fprintln(output, "https://fixture.run.app")
				return err
			}
			if testCase.mode == "deployed" {
				args[1] = filepath.Join(t.TempDir(), "config.json")
				require.NoError(t, os.WriteFile(args[1], []byte(`{"workload_project_id":"fixture-project","region":"europe-west1"}`), 0o600))
			} else {
				execute = nil
			}
			var output bytes.Buffer
			require.Equal(t, testCase.code, health.Run(t.Context(), args, execute, transport, &output, &output), output.String())
			require.Equal(t, int32(testCase.requests), calls.Load())
			if testCase.mode == "deployed" {
				require.Equal(t, 1, cloudCalls)
			}
			for _, private := range []string{"private-payload", "fixture.run.app", "fixture-project"} {
				require.NotContains(t, output.String(), private)
			}
		})
	}
}

func TestRunRejectsUnsafeInputs(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, mode, input string
		code, cloudCalls  int
	}{
		{"URL", "candidate", "http://private-payload.run.app", 70, 0},
		{"Config", "deployed", `{"workload_project_id":"private-payload","region":"--private-payload"}`, 65, 0},
		{"Discovery", "deployed", `{"workload_project_id":"fixture-project","region":"europe-west1"}`, 70, 1},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			args := []string{testCase.mode, testCase.input}
			if testCase.mode == "deployed" {
				args[1] = filepath.Join(t.TempDir(), "config.json")
				require.NoError(t, os.WriteFile(args[1], []byte(testCase.input), 0o600))
			}
			cloudCalls, connections := 0, 0
			execute := func(_ context.Context, output io.Writer, _ string, _ ...string) error {
				cloudCalls++
				_, _ = fmt.Fprintln(output, "https://private-payload.run.app")
				return fmt.Errorf("private-payload")
			}
			transport := &http.Transport{DialContext: func(context.Context, string, string) (net.Conn, error) {
				connections++
				return nil, fmt.Errorf("unexpected network request")
			}}
			var output bytes.Buffer
			require.Equal(t, testCase.code, health.Run(t.Context(), args, execute, transport, &output, &output))
			require.Equal(t, testCase.cloudCalls, cloudCalls)
			require.Zero(t, connections)
			require.NotContains(t, output.String(), "private-payload")
		})
	}
}
