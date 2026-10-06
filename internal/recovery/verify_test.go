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

func TestVerifySQL(t *testing.T) {
	t.Parallel()
	for _, service := range []string{"json-keys", "authentication"} {
		for _, tc := range []struct {
			name, fault string
		}{
			{"Success", ""},
			{"Error/PeerEvidence", "peer"},
			{"Error/Startup", "start"},
			{"Error/Identity", "identity"},
			{"Error/Schema", "schema"},
			{"Error/Data", "data"},
			{"Error/Shutdown", "stop"},
		} {
			t.Run(service+"/"+tc.name, func(t *testing.T) {
				t.Parallel()
				request := selection()
				request.Service, request.VerifySQL, request.ExpectedDataSHA256 = service, true, strings.Repeat("a", 64)
				parent := t.TempDir()
				root := filepath.Join(parent, "attempt")
				require.NoError(t, os.MkdirAll(filepath.Join(root, "data"), 0o700))
				encoded, err := json.Marshal(request)
				require.NoError(t, err)
				selectedCatalog := strings.ReplaceAll(catalog, "json-keys", service)
				if tc.fault == "peer" {
					selectedCatalog = strings.ReplaceAll(selectedCatalog, service, "unselected-service")
				}
				for name, data := range map[string]string{
					"request.json": string(encoded), "catalog.json": selectedCatalog,
					"files-restored.json":       fmt.Sprintf(`{"system_id":%q,"set":%q,"postgresql_started":false}`, request.SystemID, request.Set),
					"data/postgresql.auto.conf": "restore_command='never execute'\n",
				} {
					require.NoError(t, os.WriteFile(filepath.Join(root, name), []byte(data), 0o600))
				}
				var calls []string
				execute := func(_ context.Context, _ io.Writer, binary string, args ...string) ([]byte, error) {
					step := args[len(args)-1]
					if strings.HasSuffix(binary, "/psql") {
						role := "agora_" + strings.ReplaceAll(service, "-", "_")
						require.Equal(t, []string{"-XqAt", "-v", "ON_ERROR_STOP=1", "-h", filepath.Join(root, "verification"), "-U", role, "-d", role, "-c"}, args[:len(args)-1])
						switch {
						case strings.Contains(step, "pg_control_system"):
							step = "identity"
						case strings.Contains(step, "pg_extension"):
							require.Contains(t, step, "'"+role+"_backup'")
							step = "schema"
						default:
							require.Contains(t, step, "BEGIN READ ONLY;")
							if service == "authentication" {
								require.Contains(t, step, "public.credentials")
								require.Contains(t, step, "public.short_codes")
							} else {
								require.Contains(t, step, "public.keys")
							}
							step = "data"
						}
					}
					calls = append(calls, step)
					if step == tc.fault {
						return nil, errors.New("foo")
					}
					switch step {
					case "start", "stop":
						return nil, nil
					case "identity":
						return []byte(request.SystemID + "|t|paused"), nil
					case "schema":
						return []byte("t"), nil
					case "data":
						return []byte(request.ExpectedDataSHA256), nil
					default:
						t.Fatalf("unexpected command %s %v", binary, args)
						return nil, errors.New("unexpected command")
					}
				}
				err = recovery.VerifySQL(t.Context(), request, parent, execute)
				completion := filepath.Join(root, "verification", "sql-verified.json")
				if tc.fault == "" {
					require.NoError(t, err)
					data, err := os.ReadFile(completion)
					require.NoError(t, err)
					require.JSONEq(t, fmt.Sprintf(`{"system_id":%q,"set":%q,"postgresql_stopped":true,"data_sha256":%q}`, request.SystemID, request.Set, request.ExpectedDataSHA256), string(data))
					require.Equal(t, []string{"start", "identity", "schema", "data", "stop"}, calls)
				} else {
					require.Error(t, err)
					require.NoFileExists(t, completion)
					if tc.fault == "peer" {
						require.Empty(t, calls)
					} else {
						require.Equal(t, "stop", calls[len(calls)-1])
					}
				}
				before := len(calls)
				require.Error(t, recovery.VerifySQL(t.Context(), request, parent, execute))
				require.Len(t, calls, before, "verification must not replay an existing attempt")
			})
		}
	}
}
