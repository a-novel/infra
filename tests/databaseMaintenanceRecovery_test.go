package tests_test

import (
	"bytes"
	"encoding/json"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/a-novel/infra/internal/database"
)

func TestLegacyMaintenanceRecovery(t *testing.T) {
	t.Parallel()
	for _, scenario := range []string{"Success", "OlderHold", "SameInstance", "BothCompleted", "NeitherCompleted", "Disabled", "OutsideInterval", "SameBootDisk", "InvalidBootDisk", "AddressDrift", "WrongRuntime", "WrongLiveScript", "BusyMember", "UnstableGroup", "ReadinessFailure", "BackupFailure", "RestoreFailure", "FutureInterval", "InvalidInterval"} {
		t.Run(scenario, func(t *testing.T) {
			t.Parallel()
			cloud := newMaintenanceCloud(t)
			getenv := func(key string) string { return cloud.env[key] }
			plan, inputs, targets := filepath.Join(cloud.dir, "plan.json"), filepath.Join(cloud.dir, "inputs.json"), filepath.Join(cloud.dir, "targets.json")
			outputs, evidence := filepath.Join(cloud.dir, "outputs.json"), filepath.Join(cloud.dir, "evidence.json")
			writeJSON(t, plan, cloud.plan(t))
			writeJSON(t, inputs, object{"workload_project_id": cloud.hosts["json-keys"].project, "database_zone": cloud.hosts["json-keys"].zone, "native_backups": object{"json-keys": object{"wal_archiving": true}, "authentication": object{"wal_archiving": true}}})
			var logs bytes.Buffer
			expectCode(t, 0, database.Run(t.Context(), []string{"maintenance-plan", plan, inputs, targets}, getenv, cloud.execute, &logs, &logs), logs.String())
			if scenario == "OlderHold" {
				var held []object
				require.NoError(t, json.Unmarshal([]byte(read(t, targets)), &held))
				for _, target := range held {
					delete(target, "BootDiskID")
				}
				writeJSON(t, targets, held)
			}
			cloud.applied, cloud.scenario = true, scenario
			cloud.env["LEGACY_DATABASE_RECOVERY_ENABLED"] = "true"
			cloud.hosts["json-keys"].writes = 1
			if scenario == "BothCompleted" {
				cloud.hosts["authentication"].writes = 1
			}
			if scenario == "NeitherCompleted" {
				cloud.hosts["json-keys"].writes = 0
			}
			if scenario == "Disabled" {
				delete(cloud.env, "LEGACY_DATABASE_RECOVERY_ENABLED")
			}
			values := object{}
			for service := range cloud.hosts {
				values[strings.ReplaceAll(service, "-", "_")] = object{"url": cloud.template(service, true), "id": "222"}
			}
			writeJSON(t, outputs, object{"database_maintenance_templates": object{"value": values}})
			start, finish := time.Now().Add(-time.Hour).Format(time.RFC3339), time.Now().Add(-10*time.Minute).Format(time.RFC3339)
			if scenario == "FutureInterval" {
				finish = time.Now().Add(time.Hour).Format(time.RFC3339)
			}
			if scenario == "InvalidInterval" {
				start = "invalid"
			}
			code := database.Run(t.Context(), []string{"maintenance-recover", targets, outputs, evidence, start, finish}, getenv, cloud.execute, &logs, &logs)
			require.NotContains(t, logs.String(), privateValue)
			if slices.Contains([]string{"Success", "OlderHold", "SameInstance", "BothCompleted", "NeitherCompleted"}, scenario) {
				expectCode(t, 0, code, logs.String())
				events := []string{"backup/authentication", "restore/authentication", "replace/authentication"}
				switch scenario {
				case "BothCompleted":
					events = nil
				case "NeitherCompleted":
					events = []string{"backup/json-keys", "restore/json-keys", "backup/authentication", "restore/authentication", "replace/json-keys", "replace/authentication"}
				}
				require.Equal(t, events, cloud.events)
				var proof []object
				require.NoError(t, json.Unmarshal([]byte(read(t, evidence)), &proof))
				require.Len(t, proof, 2)
				if scenario != "NeitherCompleted" {
					require.Equal(t, true, proof[0]["reconciled"])
					require.NotContains(t, proof[0], "backupExecution")
				}
			} else {
				want := 70
				if scenario == "Disabled" || scenario == "FutureInterval" {
					want = 77
				}
				if scenario == "InvalidInterval" {
					want = 65
				}
				expectCode(t, want, code, logs.String())
				require.NoFileExists(t, evidence)
				require.NotContains(t, cloud.events, "replace/json-keys")
				require.NotContains(t, cloud.events, "replace/authentication")
			}
		})
	}
}
