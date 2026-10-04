package health_test

import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/a-novel/infra/internal/health"
)

func TestCheck(t *testing.T) {
	t.Parallel()
	const jsonKeys = `{"client:postgres":{"status":"up"}}`
	for _, testCase := range []struct {
		name, service, body string
		status, calls       int
		valid               bool
	}{
		{"Success/JSONKeys", "json-keys", jsonKeys, 200, 1, true},
		{"Success/Authentication", "authentication", healthy, 200, 1, true},
		{"Error/UnknownService", "platform", healthy, 200, 0, false},
		{"Error/WrongContract", "json-keys", healthy, 200, 1, false},
		{"Error/MissingDependencies", "authentication", jsonKeys, 200, 1, false},
		{"Error/Empty", "json-keys", `{}`, 200, 1, false},
		{"Error/Down", "json-keys", strings.ReplaceAll(jsonKeys, "up", "down"), 503, 1, false},
		{"Error/Down200", "json-keys", strings.ReplaceAll(jsonKeys, "up", "down"), 200, 1, false},
		{"Error/Healthy503", "json-keys", jsonKeys, 503, 1, false},
		{"Error/Redirect", "json-keys", jsonKeys, 302, 1, false},
		{"Error/Forbidden", "json-keys", "private-payload", 403, 1, false},
		{"Error/Payload", "json-keys", `{"client:postgres":{"status":"up","error":"private-payload"}}`, 200, 1, false},
		{"Error/Status", "json-keys", strings.ReplaceAll(jsonKeys, "up", "private-payload"), 200, 1, false},
		{"Error/Oversized", "json-keys", jsonKeys + strings.Repeat(" ", 4096), 200, 1, false},
		{"Error/TwoDocuments", "json-keys", jsonKeys + jsonKeys, 200, 1, false},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			var calls atomic.Int32
			server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls.Add(1)
				if r.Method != http.MethodGet || r.URL.Path != "/v2/healthcheck" || r.Header.Get("Authorization") != "" || r.Header.Get("Cookie") != "" {
					t.Error("unexpected public health request or credentials")
				}
				w.Header().Set("Location", "https://other.run.app")
				w.WriteHeader(testCase.status)
				_, _ = io.WriteString(w, testCase.body)
			}))
			t.Cleanup(server.Close)
			transport := server.Client().Transport.(*http.Transport)
			transport.TLSClientConfig.ServerName = server.Certificate().DNSNames[0]
			transport.DialContext = func(ctx context.Context, network, _ string) (net.Conn, error) {
				return (&net.Dialer{}).DialContext(ctx, network, server.Listener.Addr().String())
			}
			err := health.Check(t.Context(), testCase.service, "https://candidate---fixture.run.app", transport)
			require.EqualValues(t, testCase.calls, calls.Load())
			if testCase.valid {
				require.NoError(t, err)
			} else {
				require.Error(t, err)
				require.NotContains(t, err.Error(), "private-payload")
			}
		})
	}
}

func TestCheckRejectsUnsafeURLs(t *testing.T) {
	t.Parallel()
	for _, url := range []string{
		"http://fixture.run.app",
		"https://fixture.run.app.attacker.example",
		"https://user:password@fixture.run.app",
		"https://fixture.run.app:8443",
		"https://fixture.run.app/private-payload",
		"https://fixture.run.app?private-payload",
		"http://metadata.google.internal",
		"https://" + strings.Repeat("a", 250) + ".run.app",
	} {
		t.Run(url, func(t *testing.T) {
			t.Parallel()
			var calls atomic.Int32
			transport := &http.Transport{DialContext: func(context.Context, string, string) (net.Conn, error) {
				calls.Add(1)
				return nil, errors.New("unexpected network request")
			}}
			err := health.Check(t.Context(), "json-keys", url, transport)
			require.Error(t, err)
			require.Zero(t, calls.Load())
			require.NotContains(t, err.Error(), url)
		})
	}
}
