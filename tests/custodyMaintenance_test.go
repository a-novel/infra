package tests_test

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"google.golang.org/api/option"

	"github.com/a-novel/infra/internal/custody"
)

// Exercise the public apply boundary: real conditional guard writes, existing
// private-plan transport, and only the provider/SSH leaves replaced locally.
func TestCustodyMaintenance(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name string
		code int
	}{
		{"Ready", 0},
		{"NoOp", 0},
		{"MonitoringOnly", 0},
		{"InitialCreation", 0},
		{"StoppedHosts", 0},
		{"Disabled", 77},
		{"WrongWorkflow", 77},
		{"MissingDatabase", 65},
		{"LegacyHost", 65},
		{"PeerProject", 65},
		{"ChangedInstance", 70},
		{"ChangedRuntime", 70},
		{"Transitioning", 70},
		{"StopUncertain", 70},
		{"MissingUnit", 70},
		{"ActiveUnit", 70},
		{"PendingJob", 70},
		{"RemainingContainer", 70},
		{"RepositoryUnavailable", 70},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			f, args, metadataFile := planFixture(t, "service-foundation", "services/agora-json-keys-test")
			config := readJSON(t, args[5])
			config["database_runtime"] = object{"revision": strings.Repeat("b", 40)}
			writeJSON(t, args[5], config)
			metadata := readJSON(t, metadataFile)
			metadata["inputsSha256"] = fmt.Sprintf("%x", sha256.Sum256([]byte(read(t, args[5]))))
			writeJSON(t, metadataFile, metadata)
			f.env["SERVICE_FOUNDATIONS_ENABLED"], f.env["NATIVE_BACKUP_MAINTENANCE_ENABLED"] = "true", "true"
			f.env["GITHUB_SHA"], f.env["GITHUB_RUN_ID"], f.env["GITHUB_RUN_ATTEMPT"] = args[2], "124", "1"
			f.env["GITHUB_REPOSITORY"], f.env["GITHUB_EVENT_NAME"] = "a-novel/infra", "workflow_dispatch"
			f.env["GITHUB_WORKFLOW_REF"] = "a-novel/infra/.github/workflows/foundation.yaml@refs/heads/master"
			f.env["MANAGEMENT_PROJECT_ID"] = "agora-management-test"
			f.env["FOUNDATION_CONFIG"] = `{"management_project_id":"agora-management-test","workload_project_id":"agora-production-test","region":"europe-west1","service_projects":{"json-keys":"agora-json-keys-test"}}`
			applyStorage(t, f, "")
			remotePlan := filepath.Join(filepath.Dir(metadataFile), "plan.tfplan")
			guard := filepath.Join(f.env["FAKE_GCS_ROOT"], args[0], "services/agora-json-keys-test/release/operation.json")

			hosts := []object{
				{"name": "agora-database-json-keys-abcd", "instance_id": "123", "metadata": object{"user-data": "/etc/systemd/system/agora-database.service"}},
				{"name": "agora-pgbackrest-json-keys", "instance_id": "456", "metadata": object{"user-data": "/etc/systemd/system/agora-backup-repository.service"}},
			}
			for _, host := range hosts {
				host["project"], host["zone"] = "agora-json-keys-test", "europe-west1-b"
			}
			resources := []object{
				{"address": `data.google_compute_instance.database["host"]`, "values": hosts[0]},
				{"address": `google_compute_instance.repository["host"]`, "values": hosts[1]},
				{"address": `google_compute_instance_group_manager.database["host"]`, "values": object{}},
			}
			change := object{"address": `google_compute_instance_template.database["host"]`, "change": object{"actions": []string{"delete", "create"}}}
			switch testCase.name {
			case "NoOp":
				nested(change, "change")["actions"] = []string{"no-op"}
			case "MonitoringOnly":
				change["address"] = "google_monitoring_alert_policy.backup"
			case "InitialCreation":
				resources = nil
			case "Disabled":
				f.env["NATIVE_BACKUP_MAINTENANCE_ENABLED"] = "false"
			case "WrongWorkflow":
				f.env["GITHUB_WORKFLOW_REF"] = "a-novel/infra/.github/workflows/release.yaml@refs/heads/master"
			case "MissingDatabase":
				resources = resources[1:]
			case "LegacyHost":
				hosts[0]["metadata"] = object{"startup-script": privateValue}
			case "PeerProject":
				hosts[0]["project"] = "agora-authentication-test"
			}
			plan := object{
				"format_version": "1.2", "resource_changes": []object{change},
				"prior_state": object{"values": object{"root_module": object{"resources": resources}}},
			}
			var events []string
			execute := func(ctx context.Context, output io.Writer, command string, values ...string) error {
				if command == "env" {
					action := values[3]
					if action == "inspect" {
						writeJSON(t, values[6]+".json", plan)
						return nil
					}
					assert.FileExists(t, guard, "apply/converge require admission")
					assert.NoFileExists(t, remotePlan, "plan must be consumed first")
					events = append(events, action)
					return nil
				}
				if command == "gcloud" && values[0] == "compute" {
					assert.FileExists(t, guard, "maintenance requires admission")
					assert.NoFileExists(t, remotePlan, "maintenance cannot leave a replayable plan")
					index := 0
					if slices.Contains(values, hosts[1]["name"].(string)) {
						index = 1
					}
					if index == 1 && testCase.name == "RepositoryUnavailable" {
						return errors.New(privateValue)
					}
					if values[1] == "instances" {
						vm := object{
							"id": hosts[index]["instance_id"], "name": hosts[index]["name"], "status": "RUNNING",
							"zone":     "https://www.googleapis.com/compute/v1/projects/agora-json-keys-test/zones/europe-west1-b",
							"metadata": object{"items": []object{{"key": "user-data", "value": nested(hosts[index], "metadata")["user-data"]}}},
						}
						switch testCase.name {
						case "ChangedInstance":
							vm["id"] = "789"
						case "ChangedRuntime":
							vm["metadata"] = object{}
						case "Transitioning":
							vm["status"] = "STOPPING"
						case "StoppedHosts":
							vm["status"] = "TERMINATED"
						}
						return json.NewEncoder(output).Encode(vm)
					}
					assert.Contains(t, values, "--tunnel-through-iap")
					remote := values[len(values)-1]
					assert.Contains(t, remote, "instance/id)")
					switch {
					case strings.Contains(remote, "systemctl stop "):
						_, units, _ := strings.Cut(remote, "systemctl stop ")
						events = append(events, strings.Fields(units)[0])
						if testCase.name == "StopUncertain" {
							return errors.New(privateValue)
						}
					case strings.Contains(remote, "systemctl show "):
						result := "LoadState=loaded\nActiveState=inactive\nJob=\n"
						switch testCase.name {
						case "MissingUnit":
							result = strings.ReplaceAll(result, "loaded", "not-found")
						case "ActiveUnit":
							result = strings.ReplaceAll(result, "inactive", "active")
						case "PendingJob":
							result = strings.ReplaceAll(result, "Job=", "Job=42")
						}
						_, err := io.WriteString(output, result)
						return err
					case strings.Contains(remote, "docker ps "):
						if testCase.name == "RemainingContainer" {
							_, err := io.WriteString(output, "agora-backup-full\n")
							return err
						}
					default:
						t.Errorf("unexpected remote command: %s", remote)
					}
					return nil
				}
				assert.Equal(t, "gcloud", command)
				assert.Equal(t, "storage", values[0])
				cmd := exec.CommandContext(ctx, filepath.Join(f.bin, command), values...)
				cmd.Stdout, cmd.Stderr = output, output
				for key, value := range f.env {
					cmd.Env = append(cmd.Env, key+"="+value)
				}
				return cmd.Run()
			}
			var stdout, stderr bytes.Buffer
			code := custody.Run(t.Context(), []string{"plan", "apply", args[0], args[1], args[2], args[3], args[5]},
				func(key string) string { return f.env[key] }, execute, &stdout, &stderr,
				option.WithEndpoint(f.env["TEST_STORAGE_ENDPOINT"]), option.WithoutAuthentication())
			expectCode(t, testCase.code, code, stdout.String()+stderr.String())
			switch testCase.code {
			case 0:
				want := []string{"apply", "converge"}
				if testCase.name == "Ready" {
					want = append([]string{"agora-backup-full.timer", "agora-backup-stanza-create.service", "agora-database.service", "agora-backup-repository.service"}, want...)
				}
				assert.Equal(t, want, events)
				assert.NoFileExists(t, guard)
			case 70:
				assert.NotContains(t, events, "apply")
				assert.FileExists(t, guard)
			default:
				assert.Empty(t, events)
				assert.NoFileExists(t, guard)
				require.FileExists(t, remotePlan)
			}
		})
	}
}
