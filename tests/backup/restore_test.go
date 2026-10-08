package backup_test

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/a-novel/infra/internal/recovery"
)

// TestNativeRestore exercises the production worker with native tools and local synthetic storage.
func TestNativeRestore(t *testing.T) {
	if os.Getenv("BACKUP_TEST") != "1" {
		t.Skip("run inside builds/backup-test.Dockerfile")
	}
	p := newProof(t, "json-keys")
	p.backrest(t, "--type=full", "backup")
	request := recovery.Request{
		Service: "json-keys", SourceProject: "source-project", Project: "a-novel-recovery-proof",
		ManagementProject: "management-project", ManagementNumber: "123456789012", Major: 18,
		SystemID: strings.TrimSpace(p.sql(t, "SELECT system_identifier FROM pg_control_system();")), Set: p.backups(t)[0].Label,
	}
	for _, tc := range []struct {
		name   string
		change func(*recovery.Request)
		fail   bool
	}{
		{"Success", func(*recovery.Request) {}, false},
		{"Error/DatabaseIdentity", func(r *recovery.Request) { r.SystemID = "1234567890123456789" }, true},
		{"Error/MissingSet", func(r *recovery.Request) { r.Set = "20000101-000000F" }, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			selected := request
			tc.change(&selected)
			parent := t.TempDir()
			execute := func(ctx context.Context, diagnostics io.Writer, binary string, args ...string) ([]byte, error) {
				// Only transport differs: every selection, identity check and restore option stays real.
				if binary == "/usr/bin/pgbackrest" {
					local := []string{}
					for _, arg := range args {
						if strings.HasPrefix(arg, "--repo1-") {
							continue
						}
						local = append(local, arg)
					}
					args = append([]string{"--repo1-type=posix", "--repo1-path=" + p.repo}, local...)
				}
				output, err := recovery.Command(ctx, diagnostics, binary, args...)
				if err != nil {
					t.Logf("synthetic native diagnostics: %s", output)
				}
				return output, err
			}
			err := recovery.Restore(t.Context(), selected, parent, execute)
			if tc.fail {
				require.ErrorContains(t, err, "exact backup does not identify the approved database")
			} else {
				require.NoError(t, err)
				outcome, err := os.ReadFile(filepath.Join(parent, "attempt", "files-restored.json"))
				require.NoError(t, err)
				require.Contains(t, string(outcome), `"postgresql_started":false`)
			}
			require.ErrorContains(t, recovery.Restore(t.Context(), selected, parent, execute), "already used")
			_, err = os.Stat(filepath.Join(parent, "attempt", "data", "postmaster.pid"))
			require.True(t, os.IsNotExist(err), "worker must never start PostgreSQL")
		})
	}
}
