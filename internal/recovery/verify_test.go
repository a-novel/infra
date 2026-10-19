package recovery_test

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/a-novel/infra/internal/recovery"
)

// writeRestoreEvidence leaves in root what a completed file restoration of request leaves. With
// peer set, its catalog names another service.
func writeRestoreEvidence(t *testing.T, root string, request recovery.Request, peer bool) {
	t.Helper()
	require.NoError(t, os.MkdirAll(filepath.Join(root, "data"), 0o700))
	encoded, err := json.Marshal(request)
	require.NoError(t, err)
	selectedCatalog := strings.ReplaceAll(catalog, "json-keys", request.Service)
	if peer {
		selectedCatalog = strings.ReplaceAll(selectedCatalog, request.Service, "unselected-service")
	}
	files := map[string]string{
		"request.json": string(encoded), "catalog.json": selectedCatalog,
		"files-restored.json":       fmt.Sprintf(`{"system_id":%q,"set":%q,"postgresql_started":false}`, request.SystemID, request.Set),
		"data/postgresql.auto.conf": "restore_command='never execute'\n",
	}
	for name, data := range files {
		require.NoError(t, os.WriteFile(filepath.Join(root, name), []byte(data), 0o600))
	}
}

// fakePostgres answers the native calls VerifySQL makes for request, fails the step named fault,
// and records each step it runs.
type fakePostgres struct {
	t       *testing.T
	request recovery.Request
	socket  string
	fault   string
	calls   []string
}

func (f *fakePostgres) execute(_ context.Context, _ io.Writer, binary string, args ...string) ([]byte, error) {
	step := args[len(args)-1]
	if strings.HasSuffix(binary, "/psql") {
		step = f.query(args)
	}
	f.calls = append(f.calls, step)
	if step == f.fault {
		return nil, errors.New("foo")
	}
	switch step {
	case "start", "stop":
		return nil, nil
	case "identity":
		return []byte(f.request.SystemID + "|t|paused"), nil
	case "schema":
		return []byte("t"), nil
	case "data":
		return []byte(f.request.ExpectedDataSHA256), nil
	default:
		f.t.Fatalf("unexpected command %s %v", binary, args)
		return nil, errors.New("unexpected command")
	}
}

// query checks how a psql call connects, and names the step its SQL runs.
func (f *fakePostgres) query(args []string) string {
	sql := args[len(args)-1]
	role := "agora_" + strings.ReplaceAll(f.request.Service, "-", "_")
	require.Equal(f.t, []string{"-XqAt", "-v", "ON_ERROR_STOP=1", "-h", f.socket, "-U", role, "-d", role, "-c"}, args[:len(args)-1])
	switch {
	case strings.Contains(sql, "pg_control_system"):
		return "identity"
	case strings.Contains(sql, "pg_extension"):
		require.Contains(f.t, sql, "'"+role+"_backup'")
		require.Contains(f.t, sql, "'"+role+"_app'")
		return "schema"
	default:
		require.Contains(f.t, sql, "BEGIN READ ONLY;")
		if f.request.Service == "authentication" {
			require.Contains(f.t, sql, "public.credentials")
			require.Contains(f.t, sql, "public.short_codes")
		} else {
			require.Contains(f.t, sql, "public.keys")
		}
		return "data"
	}
}

func TestVerifySQL(t *testing.T) {
	t.Parallel()
	services := []string{"json-keys", "authentication"}
	testCases := []struct {
		name, fault string
	}{
		{"Success", ""},
		{"Error/PeerEvidence", "peer"},
		{"Error/Startup", "start"},
		{"Error/Identity", "identity"},
		{"Error/Schema", "schema"},
		{"Error/Data", "data"},
		{"Error/Shutdown", "stop"},
	}
	for _, service := range services {
		for _, tc := range testCases {
			t.Run(service+"/"+tc.name, func(t *testing.T) {
				t.Parallel()
				request := selection()
				request.Service, request.VerifySQL, request.ExpectedDataSHA256 = service, true, strings.Repeat("a", 64)
				parent := t.TempDir()
				root := filepath.Join(parent, "attempt")
				writeRestoreEvidence(t, root, request, tc.fault == "peer")
				postgres := &fakePostgres{t: t, request: request, socket: filepath.Join(root, "verification"), fault: tc.fault}
				err := recovery.VerifySQL(t.Context(), request, parent, postgres.execute)
				completion := filepath.Join(root, "verification", "sql-verified.json")
				if tc.fault == "" {
					require.NoError(t, err)
					data, err := os.ReadFile(completion)
					require.NoError(t, err)
					require.JSONEq(t, fmt.Sprintf(`{"system_id":%q,"set":%q,"postgresql_stopped":true,"data_sha256":%q}`, request.SystemID, request.Set, request.ExpectedDataSHA256), string(data))
					require.Equal(t, []string{"start", "identity", "schema", "data", "stop"}, postgres.calls)
				} else {
					require.Error(t, err)
					require.NoFileExists(t, completion)
					if tc.fault == "peer" {
						require.Empty(t, postgres.calls)
					} else {
						require.Equal(t, "stop", postgres.calls[len(postgres.calls)-1])
					}
				}
				before := len(postgres.calls)
				require.Error(t, recovery.VerifySQL(t.Context(), request, parent, postgres.execute))
				require.Len(t, postgres.calls, before, "verification must not replay an existing attempt")
			})
		}
	}
}
