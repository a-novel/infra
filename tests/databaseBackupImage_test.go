package tests_test

import (
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestDatabaseBackupImage(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, supervised, digest string
		code                     int
	}{
		{"Success/Native", "true", strings.Repeat("a", 64), 0},
		{"Success/Legacy", "false", strings.Repeat("b", 64), 0},
		{"Error/NativeMismatch", "true", strings.Repeat("b", 64), 1},
		{"Error/NativeUnpinned", "true", "latest", 1},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			f := setup(t)
			f.env["DATABASE_SUPERVISED"] = testCase.supervised
			f.env["PGBACKREST_DATABASE_IMAGE"] = "registry/private/database@sha256:" + testCase.digest
			_, body, found := strings.Cut(read(t, filepath.Join(f.root, "assets", "database-host", "startup.sh")), "require_promoted_image() {\n")
			require.True(t, found)
			body, _, found = strings.Cut(body, "\nfetch_secret() {")
			require.True(t, found)
			code, out := f.run(t, "bash", "-c", "set -eu\nrequire_promoted_image() {\n"+body+`
REGISTRY_HOST=example-docker.pkg.dev
WORKLOAD_PROJECT_ID=example-private
require_promoted_image "example-docker.pkg.dev/example-private/agora-production/database@sha256:`+strings.Repeat("a", 64)+`" database
`)
			expectCode(t, testCase.code, code, out)
		})
	}
}
