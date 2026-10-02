package tests_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestDatabaseCollationPreparation(t *testing.T) {
	t.Parallel()
	for _, script := range []string{"startup.sh", "legacy-startup.sh"} {
		t.Run(script, func(t *testing.T) {
			t.Parallel()
			for _, tc := range []struct {
				name, status string
				existing     bool
				code         int
			}{
				{"Success/Fresh", "0", false, 0},
				{"Success/Existing", "0", true, 0},
				{"Error/Preparation", "17", true, 1},
				{"Error/Timeout", "124", true, 1},
			} {
				t.Run(tc.name, func(t *testing.T) {
					t.Parallel()
					f := setup(t)
					f.env["PREPARATION_STATUS"] = tc.status
					data := filepath.Join(f.dir, "data with spaces")
					if tc.existing {
						require.NoError(t, os.MkdirAll(filepath.Join(data, "18", "docker"), 0o700))
						require.NoError(t, os.WriteFile(filepath.Join(data, "18", "docker", "PG_VERSION"), []byte("18\n"), 0o600))
					}
					_, body, found := strings.Cut(read(t, filepath.Join(f.root, "assets", "database-host", script)), "prepare_database_collations() {\n")
					require.True(t, found)
					body, _, found = strings.Cut(body, "\nstart_database() {")
					require.True(t, found)
					code, out := f.run(t, "bash", "-c", "set -eu\nprepare_database_collations() {\n"+body+`
CONTAINER_CPU=0.75
CONTAINER_MEMORY_MB=1536
docker() {
    printf '%s\n' "$@" > "$TMPDIR/arguments"
    cat > "$TMPDIR/preparation"
    printf 'private database diagnostic\n' >&2
    return "$PREPARATION_STATUS"
}
prepare_database_collations database:test "$TMPDIR/data with spaces" owner database
`)
					expectCode(t, tc.code, code, out)
					require.NotContains(t, out, "private database diagnostic")
					if !tc.existing {
						require.NoFileExists(t, filepath.Join(f.dir, "arguments"))
						return
					}
					require.Equal(t, []string{
						"run", "--rm", "--interactive", "--network", "none", "--read-only", "--user", "postgres", "--no-healthcheck",
						"--cap-drop", "ALL", "--security-opt", "no-new-privileges", "--cpus", "0.75", "--memory", "1536m",
						"--memory-swap", "1536m", "--pids-limit", "128", "--tmpfs", "/tmp:rw,nosuid,nodev,noexec,size=32m,mode=1777",
						"--mount", "type=bind,source=" + data + ",target=/var/lib/postgresql", "--entrypoint", "timeout",
						"database:test", "-k", "15", "120", "/bin/bash", "-se", "--", "owner", "database",
					}, strings.Split(strings.TrimSpace(read(t, filepath.Join(f.dir, "arguments"))), "\n"))
					if tc.code != 0 {
						require.Contains(t, out, "error: isolated database collation preparation failed")
					}
				})
			}
		})
	}
}

func TestPostgresArchiveValidation(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name, diagnostics, archive, restoreStatus, message string
		code                                               int
	}{
		{"Success", "", "archive", "0", "", 0},
		{"Error/Diagnostics", "private warning", "archive", "0", "pg_dump emitted diagnostics", 1},
		{"Error/Empty", "", "", "0", "empty archive", 1},
		{"Error/Unreadable", "", "archive", "1", "pg_restore could not read archive", 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			f := setup(t)
			f.env["RESTORE_STATUS"] = tc.restoreStatus
			require.NoError(t, os.WriteFile(filepath.Join(f.dir, "dump.log"), []byte(tc.diagnostics), 0o600))
			require.NoError(t, os.WriteFile(filepath.Join(f.dir, "database.dump"), []byte(tc.archive), 0o600))
			_, body, found := strings.Cut(read(t, filepath.Join(f.root, "environments/production/release/scripts/postgres-backup.sh")), "# Treat a warning as an incomplete recovery point.")
			require.True(t, found)
			body, _, found = strings.Cut(body, "DUMP_SIZE_BYTES=")
			require.True(t, found)
			code, out := f.run(t, "bash", "-c", `set -eu
PG_DUMP_LOG="$TMPDIR/dump.log"
DUMP_FILE="$TMPDIR/database.dump"
pg_restore() { printf 'private restore diagnostic\n' >&2; return "$RESTORE_STATUS"; }
# Treat a warning as an incomplete recovery point.`+body)
			expectCode(t, tc.code, code, out)
			require.NotContains(t, out, "private")
			if tc.code != 0 {
				require.Contains(t, out, tc.message)
			}
		})
	}
}
