package tests_test

import (
	"bytes"
	"encoding/json"
	"maps"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/a-novel/infra/internal/database"
)

func TestDatabaseImageMaintenance(t *testing.T) {
	t.Parallel()
	for _, scenario := range []string{"Success", "Disabled", "PasswordChange", "BackupPasswordChange", "ForeignImage", "SameRevision", "RevisionOnly", "ExtraMetadata", "ExtraLabels", "CapacityChange", "DiskChange", "MixedMaintenance", "LiveMetadataDrift", "GroupMetadataDrift", "MemberMetadataDrift", "ReplacedInstance", "ReplacedBootDisk", "StaleBackup", "BackupFailure", "RestoreFailure", "ReplaceFailure", "ReadinessFailure", "Recovery", "OutsideInterval", "RecoveryBeforeRestart"} {
		t.Run(scenario, func(t *testing.T) {
			t.Parallel()
			cloud := newMaintenanceCloud(t)
			plan := cloud.plan(t)
			changes := plan["resource_changes"].([]object)
			for _, change := range changes {
				nested(change, "change")["actions"] = []string{"no-op"}
			}
			group := nested(changes[4], "change")
			group["actions"] = []string{"update"}
			selected := cloud.hosts["authentication"]
			after := maps.Clone(selected.metadata)
			after[isolationRevision] = strings.Repeat("c", 40)
			imageKey := "agora-authentication-database-image"
			after[imageKey] = strings.Split(after[imageKey], "@sha256:")[0] + "@sha256:" + strings.Repeat("d", 64)
			nested(group, "after")["all_instances_config"] = []object{{"metadata": after}}
			cloud.imageUpdates = map[string]map[string]string{"authentication": after}
			wantPlan := 0
			switch scenario {
			case "Disabled":
				cloud.env["LEGACY_DATABASE_MAINTENANCE_ENABLED"], wantPlan = "false", 77
			case "PasswordChange":
				after["agora-authentication-postgres-password-version"], wantPlan = "99", 65
			case "BackupPasswordChange":
				after["agora-authentication-postgres-backup-password-version"], wantPlan = "99", 65
			case "ForeignImage":
				after[imageKey], wantPlan = strings.ReplaceAll(after[imageKey], "service-authentication", "service-json-keys"), 65
			case "SameRevision":
				after[isolationRevision], wantPlan = selected.metadata[isolationRevision], 65
			case "RevisionOnly":
				after[imageKey], wantPlan = selected.metadata[imageKey], 65
			case "ExtraMetadata":
				after["unreviewed"], wantPlan = "value", 65
			case "ExtraLabels":
				nested(group, "after")["all_instances_config"] = []object{{"metadata": after, "labels": object{"other": "value"}}}
				wantPlan = 65
			case "CapacityChange":
				nested(group, "after")["target_size"], wantPlan = 2, 65
			case "DiskChange":
				nested(changes[5], "change")["actions"], wantPlan = []string{"update"}, 65
			case "MixedMaintenance":
				nested(changes[0], "change")["actions"] = []string{"create", "delete"}
				nested(changes[1], "change")["actions"] = []string{"update"}
				wantPlan = 65
			case "LiveMetadataDrift":
				selected.metadata = maps.Clone(selected.metadata)
				selected.metadata[isolationRevision], wantPlan = strings.Repeat("e", 40), 70
			}
			planPath, inputs, targets := filepath.Join(cloud.dir, "plan.json"), filepath.Join(cloud.dir, "inputs.json"), filepath.Join(cloud.dir, "targets.json")
			outputs, evidence := filepath.Join(cloud.dir, "outputs.json"), filepath.Join(cloud.dir, "evidence.json")
			writeJSON(t, planPath, plan)
			writeJSON(t, inputs, object{"workload_project_id": selected.project, "database_zone": selected.zone, "native_backups": object{"authentication": object{"wal_archiving": true}, "json-keys": object{"wal_archiving": true}}})
			getenv := func(key string) string { return cloud.env[key] }
			var logs bytes.Buffer
			code := database.Run(t.Context(), []string{"maintenance-plan", planPath, inputs, targets}, getenv, cloud.execute, &logs, &logs)
			expectCode(t, wantPlan, code, logs.String())
			require.Empty(t, cloud.events)
			if wantPlan != 0 {
				require.NoFileExists(t, targets)
				return
			}
			cloud.applied, cloud.scenario = true, scenario
			writeJSON(t, outputs, object{"database_maintenance_templates": object{"value": object{"authentication": object{"url": cloud.template("authentication", false), "id": "111"}}}})
			args := []string{"maintenance-replace", targets, outputs, evidence}
			isRecovery := scenario == "Recovery" || scenario == "OutsideInterval" || scenario == "RecoveryBeforeRestart"
			if isRecovery {
				cloud.env["LEGACY_DATABASE_RECOVERY_ENABLED"] = "true"
				if scenario != "RecoveryBeforeRestart" {
					selected.writes = 1
					selected.metadata = maps.Clone(after)
				}
				args[0] = "maintenance-recover"
				now := time.Now()
				args = append(args, now.Add(-time.Hour).Format(time.RFC3339), now.Add(-10*time.Minute).Format(time.RFC3339))
			}
			code = database.Run(t.Context(), args, getenv, cloud.execute, &logs, &logs)
			require.NotContains(t, logs.String(), privateValue)
			if scenario == "Success" || scenario == "Recovery" {
				expectCode(t, 0, code, logs.String())
				var records []object
				require.NoError(t, json.Unmarshal([]byte(read(t, evidence)), &records))
				require.Len(t, records, 1)
				require.Equal(t, "333", records[0]["newInstanceId"])
				require.Equal(t, "555", records[0]["bootDiskId"])
				if scenario == "Success" {
					require.Equal(t, []string{"backup/authentication", "restore/authentication", "restart/authentication"}, cloud.events)
				}
			} else {
				expectCode(t, 70, code, logs.String())
				require.NoFileExists(t, evidence)
			}
			if isRecovery {
				require.Empty(t, cloud.events, "recovery must never replay a restart")
			}
			if scenario == "StaleBackup" || scenario == "BackupFailure" || scenario == "RestoreFailure" {
				require.Zero(t, selected.writes, "failed safety checks must not restart the database")
			}
			require.Zero(t, cloud.hosts["json-keys"].writes)
		})
	}
}
