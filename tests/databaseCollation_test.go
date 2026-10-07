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
			code, out := f.run(t, "bash", "-c", `
. assets/database-host/startup.sh
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
}
