package tests_test

import (
	"bytes"
	"maps"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/a-novel/infra/internal/database"
)

func TestDatabaseCredentialRetirement(t *testing.T) {
	t.Parallel()
	for _, scenario := range []string{"Success", "NativeContract", "OwnerChange", "ImageChange", "RevisionChange", "ExtraMetadata", "ExtraLabels", "RetainedBackup", "GroupMetadataDrift", "MemberMetadataDrift", "BackupFailure", "RestoreFailure", "Recovery"} {
		t.Run(scenario, func(t *testing.T) {
			t.Parallel()
			cloud := newMaintenanceCloud(t)
			if scenario == "NativeContract" {
				for service, host := range cloud.hosts {
					delete(host.metadata, "agora-"+service+"-postgres-backup-password-version")
				}
			}
			plan := cloud.plan(t)
			changes := plan["resource_changes"].([]object)
			cloud.metadataUpdates = map[string]map[string]string{}
			for index, service := range []string{"json-keys", "authentication"} {
				after := maps.Clone(cloud.hosts[service].metadata)
				delete(after, "agora-"+service+"-postgres-backup-password-version")
				cloud.metadataUpdates[service] = after
				nested(changes[index*3+1], "change", "after")["all_instances_config"] = []object{{"metadata": after}}
			}
			after := cloud.metadataUpdates["json-keys"]
			wantPlan := 0
			switch scenario {
			case "OwnerChange":
				after["agora-json-keys-postgres-password-version"], wantPlan = "99", 65
			case "ImageChange":
				after["agora-json-keys-database-image"], wantPlan = "foreign", 65
			case "RevisionChange":
				after[isolationRevision], wantPlan = strings.Repeat("d", 40), 65
			case "ExtraMetadata":
				after["unexpected"], wantPlan = "value", 65
			case "ExtraLabels":
				nested(changes[1], "change", "after")["all_instances_config"] = []object{{"metadata": after, "labels": object{"other": "value"}}}
				wantPlan = 65
			case "RetainedBackup":
				after["agora-json-keys-postgres-backup-password-version"], wantPlan = "99", 65
			}
			planPath, inputs, targets := filepath.Join(cloud.dir, "plan.json"), filepath.Join(cloud.dir, "inputs.json"), filepath.Join(cloud.dir, "targets.json")
			outputs, evidence := filepath.Join(cloud.dir, "outputs.json"), filepath.Join(cloud.dir, "evidence.json")
			writeJSON(t, planPath, plan)
			writeJSON(t, inputs, object{"workload_project_id": cloud.hosts["json-keys"].project, "database_zone": cloud.hosts["json-keys"].zone, "native_backups": object{"json-keys": object{"wal_archiving": true}, "authentication": object{"wal_archiving": true}}})
			getenv := func(key string) string { return cloud.env[key] }
			var logs bytes.Buffer
			expectCode(t, wantPlan, database.Run(t.Context(), []string{"maintenance-plan", planPath, inputs, targets}, getenv, cloud.execute, &logs, &logs), logs.String())
			require.Empty(t, cloud.events)
			if wantPlan != 0 {
				require.NoFileExists(t, targets)
				return
			}
			cloud.applied, cloud.scenario = true, scenario
			values := object{}
			for service := range cloud.hosts {
				values[strings.ReplaceAll(service, "-", "_")] = object{"url": cloud.template(service, true), "id": "222"}
			}
			writeJSON(t, outputs, object{"database_maintenance_templates": object{"value": values}})
			args := []string{"maintenance-replace", targets, outputs, evidence}
			if scenario == "Recovery" {
				cloud.env["LEGACY_DATABASE_RECOVERY_ENABLED"] = "true"
				cloud.hosts["json-keys"].writes = 1
				cloud.hosts["json-keys"].metadata = maps.Clone(cloud.metadataUpdates["json-keys"])
				args[0] = "maintenance-recover"
				now := time.Now()
				args = append(args, now.Add(-time.Hour).Format(time.RFC3339), now.Add(-10*time.Minute).Format(time.RFC3339))
			}
			want := 70
			if scenario == "Success" || scenario == "NativeContract" || scenario == "Recovery" {
				want = 0
			}
			expectCode(t, want, database.Run(t.Context(), args, getenv, cloud.execute, &logs, &logs), logs.String())
			if want != 0 {
				require.NoFileExists(t, evidence)
				if scenario != "MemberMetadataDrift" {
					require.Zero(t, cloud.hosts["json-keys"].writes)
				}
				return
			}
			require.FileExists(t, evidence)
			for service, host := range cloud.hosts {
				require.Equal(t, cloud.metadataUpdates[service], host.metadata)
				require.Equal(t, 1, host.writes)
			}
			if scenario == "Recovery" {
				require.Equal(t, []string{"backup/authentication", "restore/authentication", "replace/authentication"}, cloud.events)
			}
		})
	}
}
