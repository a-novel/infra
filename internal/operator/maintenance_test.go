package operator_test

import (
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestFoundationBackupAccess(t *testing.T) {
	t.Parallel()
	for _, enabled := range []bool{false, true} {
		t.Run(map[bool]string{false: "DefaultOff", true: "ExplicitOptIn"}[enabled], func(t *testing.T) {
			t.Parallel()
			f := foundationCase()
			writes := f.configuration()
			args := []string{"configure"}
			if enabled {
				args = append(args, "--legacy-backup-job-access")
			}
			code, output := f.run(t, args...)
			require.Zero(t, code, output)
			require.Equal(t, writes, f.mutations)
			var config map[string]any
			require.NoError(t, json.Unmarshal(f.secrets[0], &config))
			if enabled {
				require.Equal(t, true, config["legacy_backup_job_access"])
			} else {
				require.NotContains(t, config, "legacy_backup_job_access")
			}
		})
	}
}
