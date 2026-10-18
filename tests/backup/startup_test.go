package backup_test

import (
	"os"
	"os/exec"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

// TestStartupFailsClosed sources startup.sh and calls single steps, which need neither PostgreSQL nor
// Docker: a failing step must reach handle_failure, which stops the database and reports it.
func TestStartupFailsClosed(t *testing.T) {
	if os.Getenv("BACKUP_TEST") != "1" {
		t.Skip("run inside builds/backup-test.Dockerfile")
	}
	digest := "sha256:" + strings.Repeat("a", 64)
	run := func(call string) (string, error) {
		script := "source /database-startup.sh\nDATABASE_CONTAINERS=()\n" + call + "\necho survived\n"
		out, err := exec.CommandContext(t.Context(), "bash", "-c", script).CombinedOutput()
		return string(out), err
	}
	images := "REGISTRY_HOST=europe-west1-docker.pkg.dev WORKLOAD_PROJECT_ID=a-novel-production-prod DATABASE_COMPONENT=json-keys\n"
	failures := map[string]string{
		"a failed validation":      `require_numeric "container memory" abc`,
		"another service's images": images + "require_promoted_image europe-west1-docker.pkg.dev/a-novel-production-prod/agora-production/service-json-keys/database@" + digest + " service-json-keys/database",
	}
	for name, call := range failures {
		t.Run(name, func(t *testing.T) {
			out, err := run(call)
			require.Error(t, err, out)
			require.Contains(t, out, "database convergence failed")
			require.NotContains(t, out, "survived")
		})
	}
	t.Run("the service's own images", func(t *testing.T) {
		out, err := run(images + "require_promoted_image europe-west1-docker.pkg.dev/a-novel-production-prod/agora-json-keys-private-production/service-json-keys/database@" + digest + " service-json-keys/database")
		require.NoError(t, err, out)
		require.Contains(t, out, "survived")
	})
}
