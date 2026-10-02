package tests_test

import (
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

// TestDatabaseDirectory checks the image ownership contract without mounting or changing a host disk.
func TestDatabaseDirectory(t *testing.T) {
	t.Parallel()
	for _, script := range []string{"startup.sh", "legacy-startup.sh"} {
		t.Run(script, func(t *testing.T) {
			t.Parallel()
			for _, tc := range []struct {
				name, owner, status string
				code                int
			}{
				{"Success/Postgres", "999:999", "0", 0},
				{"Success/OtherOwner", "70:70", "0", 0},
				{"Error/Empty", "", "0", 1},
				{"Error/RootUser", "0:999", "0", 1},
				{"Error/RootGroup", "999:0", "0", 1},
				{"Error/Malformed", "postgres:postgres", "0", 1},
				{"Error/ExtraLine", "999:999\n70:70", "0", 1},
				{"Error/Inspection", "999:999", "17", 17},
			} {
				t.Run(tc.name, func(t *testing.T) {
					t.Parallel()
					f := setup(t)
					f.env["IMAGE_OWNER"], f.env["INSPECT_STATUS"] = tc.owner, tc.status
					// Extract only the function: the frozen legacy script runs privileged boot work when sourced.
					_, body, found := strings.Cut(read(t, filepath.Join(f.root, "assets", "database-host", script)), "prepare_database_directory() {\n")
					require.True(t, found)
					body, _, found = strings.Cut(body, "\nstart_database() {")
					require.True(t, found)
					code, out := f.run(t, "bash", "-c", "set -eu\nprepare_database_directory() {\n"+body+`
docker() {
    [ "$*" = 'run --rm --network none --read-only --entrypoint stat database:test -c %u:%g /var/lib/postgresql' ] || return 90
    printf '%s\n' "$IMAGE_OWNER"
    return "$INSPECT_STATUS"
}
install() { printf '%s\n' "$@" > "$TMPDIR/mutations"; }
chown() { printf '%s\n' "$@" >> "$TMPDIR/mutations"; }
prepare_database_directory database:test "$TMPDIR/data with spaces"
`)
					expectCode(t, tc.code, code, out)
					if tc.code != 0 {
						require.NoFileExists(t, filepath.Join(f.dir, "mutations"))
						return
					}
					require.Equal(t, "-d\n-m\n0700\n"+f.dir+"/data with spaces\n--\n"+tc.owner+"\n"+f.dir+"/data with spaces\n", read(t, filepath.Join(f.dir, "mutations")))
				})
			}
		})
	}
}
