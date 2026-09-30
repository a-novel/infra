package pgbackrest_test

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

func TestOfflineSQL(t *testing.T) {
	if os.Getenv("INFRA_PGBACKREST_PROOF") != "1" {
		t.Skip("run the disposable pgbackrest-proof image")
	}
	p := newProof(t, "json-keys")
	p.sql(t, `CREATE ROLE agora_json_keys LOGIN SUPERUSER;
CREATE ROLE agora_json_keys_backup LOGIN;
GRANT pg_read_all_data TO agora_json_keys_backup;`)
	p.sql(t, "CREATE DATABASE agora_json_keys OWNER agora_json_keys;")
	run(t, "psql", "-X", "-h", p.root, "-d", "agora_json_keys", "-v", "ON_ERROR_STOP=1", "-f", "/docker-entrypoint-initdb.d/init.sql")
	run(t, "psql", "-X", "-h", p.root, "-d", "agora_json_keys", "-v", "ON_ERROR_STOP=1", "-c", `CREATE TABLE keys (private_key text);
INSERT INTO keys VALUES ('full'); CREATE VIEW active_keys AS SELECT * FROM keys;`)
	p.backrest(t, "--type=full", "--archive-copy", "backup")
	full := p.backups(t)[0].Label
	run(t, "psql", "-X", "-h", p.root, "-d", "agora_json_keys", "-c", "UPDATE keys SET private_key='diff';")
	p.backrest(t, "--type=diff", "--archive-copy", "backup")
	diff := p.backups(t)[1].Label
	for _, set := range []string{full, diff} {
		wal := filepath.Join(p.repo, "backup/json-keys", set, "pg_data/pg_wal")
		t.Logf("copied consistency WAL stored (%s): %s", set, strings.TrimSpace(run(t, "du", "-sb", wal)))
	}
	for _, tc := range []struct{ name, set, value, fault string }{
		{"Full", full, "full", ""},
		{"Differential", diff, "diff", ""},
		{"MissingWAL", diff, "", "wal"},
		{"FailedSQL", diff, "diff", "sql"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			request := recovery.Request{
				Service: "json-keys", SourceProject: "source-project", Project: "a-novel-recovery-proof", ManagementProject: "management-project",
				ManagementNumber: "123456789012", SystemID: strings.TrimSpace(p.sql(t, "SELECT system_identifier FROM pg_control_system();")), Major: 18, Set: tc.set, VerifySQL: true,
			}
			parent := t.TempDir()
			execute := func(ctx context.Context, diagnostics io.Writer, binary string, args ...string) ([]byte, error) {
				if binary == "/usr/bin/pgbackrest" {
					local := []string{"--repo1-type=posix", "--repo1-path=" + p.repo}
					for _, arg := range args {
						if !strings.HasPrefix(arg, "--repo1-") {
							local = append(local, arg)
						}
					}
					args = local
				}
				return recovery.Command(ctx, diagnostics, binary, args...)
			}
			require.NoError(t, recovery.Restore(t.Context(), request, parent, execute))
			// Recovered configuration is evidence, not authority to load startup hooks.
			for _, name := range []string{"postgresql.conf", "postgresql.auto.conf"} {
				require.NoError(t, os.WriteFile(filepath.Join(parent, "attempt/data", name), []byte("shared_preload_libraries='unavailable_proof_library'\n"), 0o600))
			}
			wal := filepath.Join(parent, "attempt/data/pg_wal")
			entries, err := os.ReadDir(wal)
			require.NoError(t, err)
			var walBytes int64
			for _, entry := range entries {
				if entry.IsDir() {
					continue
				}
				info, err := entry.Info()
				require.NoError(t, err)
				walBytes += info.Size()
				if tc.fault == "wal" {
					require.NoError(t, os.Remove(filepath.Join(wal, entry.Name())))
				}
			}
			t.Logf("consistency WAL restored: %d bytes", walBytes)
			require.Positive(t, walBytes)
			// Verification cannot invoke pgBackRest; its startup uses only the restored WAL.
			offline := func(ctx context.Context, diagnostics io.Writer, binary string, args ...string) ([]byte, error) {
				require.NotContains(t, binary, "pgbackrest")
				if strings.HasSuffix(binary, "/psql") && strings.Contains(args[len(args)-1], "public.keys") {
					query := append(append([]string{}, args[:len(args)-1]...), "SELECT private_key FROM public.keys;")
					out, err := recovery.Command(ctx, diagnostics, binary, query...)
					require.NoError(t, err)
					require.Equal(t, tc.value, strings.TrimSpace(string(out)))
					if tc.fault == "sql" {
						return []byte("f\n"), nil
					}
				}
				return recovery.Command(ctx, diagnostics, binary, args...)
			}
			err = recovery.VerifySQL(t.Context(), request, parent, offline)
			if tc.fault == "" {
				require.NoError(t, err)
			} else {
				message := "JSON Keys recovery checks failed"
				if tc.fault == "wal" {
					message = "offline PostgreSQL startup failed"
				}
				require.ErrorContains(t, err, message)
			}
			_, resultErr := os.Stat(filepath.Join(parent, "attempt/verification/sql-verified.json"))
			require.Equal(t, tc.fault == "", resultErr == nil)
			require.NoFileExists(t, filepath.Join(parent, "attempt/data/postmaster.pid"))
			require.ErrorContains(t, recovery.VerifySQL(t.Context(), request, parent, offline), "already attempted")
		})
	}
}
