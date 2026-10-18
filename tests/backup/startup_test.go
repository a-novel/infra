package backup_test

import (
	"os"
	"os/exec"
	"testing"

	"github.com/stretchr/testify/require"
)

// TestStartupFailsClosed sources startup.sh and calls single steps, which need neither PostgreSQL nor
// Docker: a failing step must reach handle_failure, which stops the database and reports it.
func TestStartupFailsClosed(t *testing.T) {
	if os.Getenv("BACKUP_TEST") != "1" {
		t.Skip("run inside builds/backup-test.Dockerfile")
	}
	run := func(call string) (string, error) {
		script := "source /database-startup.sh\nDATABASE_CONTAINERS=()\n" + call + "\necho survived\n"
		out, err := exec.CommandContext(t.Context(), "bash", "-c", script).CombinedOutput()
		return string(out), err
	}
	failures := map[string]string{
		"a failed validation": `require_numeric "container memory" abc`,
	}
	for name, call := range failures {
		t.Run(name, func(t *testing.T) {
			out, err := run(call)
			require.Error(t, err, out)
			require.Contains(t, out, "database convergence failed")
			require.NotContains(t, out, "survived")
		})
	}
}
