package tests_test

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

func (f *sandbox) command(t *testing.T, name string) {
	t.Helper()
	binary, err := os.Executable()
	require.NoError(t, err)
	target := filepath.Join(f.bin, name)
	if strings.HasSuffix(name, ".sh") {
		target = filepath.Join(f.dir, name)
	}
	require.NoError(t, os.Symlink(binary, target))
	f.env["INFRA_TEST_COMMAND"] = "1"
	// Fixture commands finish their work before exit; avoid paying the race
	// runtime's one-second exit delay for every simulated CLI invocation.
	f.env["GORACE"] = "atexit_sleep_ms=0"
}

func TestCandidateProbe(t *testing.T) {
	t.Parallel()
	for _, status := range []int{0, 1, 14} {
		t.Run(strconv.Itoa(status), func(t *testing.T) {
			t.Parallel()
			f := setup(t)
			f.command(t, "wget")
			f.command(t, "grpcurl")
			f.env["JSON_KEYS_AUDIENCE"], f.env["JSON_KEYS_CANDIDATE"] = "https://fixture.run.app", "https://candidate---fixture.run.app"
			f.env["RPC_CODE"] = strconv.Itoa(status)
			code, out := f.run(t, "sh", filepath.Join(f.root, "environments/service-release/scripts/json-keys-smoke.sh"))
			expectCode(t, status, code, out)
			require.Equal(t, status == 0, strings.Contains(out, "health passed"))
		})
	}
}
