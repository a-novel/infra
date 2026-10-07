package tests_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/a-novel/infra/internal/database"
)

func TestLegacyMaintenance(t *testing.T) {
	t.Parallel()
	for _, scenario := range []string{
		"Success", "NumericTemplate", "ComputedFields", "BackupTag", "TagWrongJob", "TagWrongRegion", "TagOtherJob", "TagReplacement", "JobAccessDisabled", "Disabled", "ReleasesEnabled", "PauseUnset", "WrongWorkflow", "NoOp",
		"UnrelatedChange", "DiskChange", "GroupResize", "GroupVersion", "PermissionChange", "PolicyUnknown", "ImageChange", "RemovedField", "WrongReplacePath", "PriorTemplateReused",
		"MissingMetadata", "UnhealthySource", "PublicAddress", "DiskAutoDelete", "PreservationDisabled", "WrongPreservedDisk", "WrongPreservedIP", "ProactiveGroup", "Surge",
		"BusyMember", "MultipleMembers", "TemplateReused", "TemplateChangedImage", "TemplateChangedScript",
		"StaleSnapshot", "BackupFailure", "RestoreFailure", "MetadataDrift", "ChangedInstance", "ReplaceFailure", "ReadinessFailure",
		"AddressDrift", "WrongAdoptedTemplate", "SameInstance", "SameBootDisk", "InvalidBootDisk", "WrongRuntime", "WrongLiveScript",
	} {
		t.Run(scenario, func(t *testing.T) {
			t.Parallel()
			cloud := newMaintenanceCloud(t)
			cloud.scenario = scenario
			plan := cloud.plan(t)
			changes := plan["resource_changes"].([]object)
			template, group := nested(changes[0], "change"), nested(changes[1], "change")
			wantPlan := 0
			if strings.HasPrefix(scenario, "Tag") || scenario == "BackupTag" {
				job := "agora-postgres-backup-json-keys"
				if scenario == "TagOtherJob" {
					job = "agora-json-keys-rotatekeys"
				}
				after := object{"parent": "//run.googleapis.com/projects/" + cloud.hosts["json-keys"].project + "/locations/europe-west1/jobs/" + job, "location": "europe-west1"}
				if scenario == "TagWrongJob" {
					after["parent"] = "//run.googleapis.com/projects/peer-project/locations/europe-west1/jobs/" + job
				}
				if scenario == "TagWrongRegion" {
					after["location"] = "us-central1"
				}
				actions := []string{"create"}
				if scenario == "TagReplacement" {
					actions = []string{"delete", "create"}
				}
				plan["resource_changes"] = append(changes, object{"address": `google_tags_location_tag_binding.legacy_backup["` + job + `"]`, "mode": "managed", "change": object{"actions": actions, "after": after}})
				if scenario != "BackupTag" {
					wantPlan = 65
				}
			}
			switch scenario {
			case "JobAccessDisabled":
				wantPlan = 77
			case "Disabled":
				cloud.env["LEGACY_DATABASE_MAINTENANCE_ENABLED"], wantPlan = "false", 77
			case "ReleasesEnabled":
				cloud.env["PRODUCTION_RELEASES_ENABLED"], wantPlan = "true", 77
			case "PauseUnset":
				delete(cloud.env, "PRODUCTION_RELEASES_ENABLED")
				wantPlan = 77
			case "WrongWorkflow":
				cloud.env["GITHUB_WORKFLOW_REF"], wantPlan = "a-novel/infra/.github/workflows/release.yaml@refs/heads/master", 77
			case "NoOp":
				for _, change := range changes {
					nested(change, "change")["actions"] = []string{"no-op"}
				}
				cloud.env["LEGACY_DATABASE_MAINTENANCE_ENABLED"] = ""
			case "UnrelatedChange":
				plan["resource_changes"] = append(changes, object{"address": "google_compute_disk.peer", "mode": "managed", "change": object{"actions": []string{"delete"}}})
				wantPlan = 65
			case "DiskChange":
				nested(changes[2], "change")["actions"], wantPlan = []string{"update"}, 65
			case "GroupResize":
				nested(group, "after")["target_size"], wantPlan = 2, 65
			case "GroupVersion":
				nested(group, "after")["version"], wantPlan = []object{{"name": "unexpected"}}, 65
			case "PermissionChange":
				plan["resource_changes"] = append(changes, object{
					"address": `google_compute_instance_template_iam_member.database_release["json_keys"]`, "mode": "managed",
					"change": object{"actions": []string{"delete", "create"}, "before": object{"member": "original"}, "after": object{"member": "changed"}},
				})
				wantPlan = 65
			case "ComputedFields":
				delete(nested(template, "after"), "self_link")
				delete(nested(template, "after"), "numeric_id")
				template["after_unknown"] = object{"self_link": true, "numeric_id": true}
				for key, value := range (object{"min_cpu_platform": "", "disk": []object{}, "labels": object{}, "optional_count": 0}) {
					nested(template, "before")[key] = value
					nested(template, "after")[key] = nil
				}
			case "RemovedField":
				delete(nested(template, "after"), "machine_type")
				wantPlan = 65
			case "PolicyUnknown":
				nested(group, "after")["update_policy"], wantPlan = nil, 65
				group["after_unknown"] = object{"update_policy": true}
			case "ImageChange":
				nested(template, "after")["machine_type"], wantPlan = "e2-standard-4", 65
			case "WrongReplacePath":
				template["replace_paths"], wantPlan = [][]string{{"machine_type"}}, 65
			case "PriorTemplateReused", "MissingMetadata", "UnhealthySource", "PublicAddress", "DiskAutoDelete", "PreservationDisabled", "WrongPreservedDisk", "WrongPreservedIP", "ProactiveGroup", "Surge", "BusyMember", "MultipleMembers":
				wantPlan = 70
			}
			planPath, inputs, targets, outputs, evidence := filepath.Join(cloud.dir, "plan.json"), filepath.Join(cloud.dir, "inputs.json"), filepath.Join(cloud.dir, "targets.json"), filepath.Join(cloud.dir, "outputs.json"), filepath.Join(cloud.dir, "evidence.json")
			writeJSON(t, planPath, plan)
			writeJSON(t, inputs, object{"workload_project_id": cloud.hosts["json-keys"].project, "database_zone": cloud.hosts["json-keys"].zone, "legacy_backup_job_access": scenario != "JobAccessDisabled"})
			var logs bytes.Buffer
			getenv := func(key string) string { return cloud.env[key] }
			code := database.Run(t.Context(), []string{"maintenance-plan", planPath, inputs, targets}, getenv, cloud.execute, &logs, &logs)
			expectCode(t, wantPlan, code, logs.String())
			require.Empty(t, cloud.events, "admission must be read-only")
			if wantPlan != 0 {
				require.NoFileExists(t, targets)
				return
			}
			if scenario == "NoOp" {
				require.Equal(t, "null", read(t, targets))
				return
			}
			cloud.applied = true
			values := object{}
			for service := range cloud.hosts {
				values[strings.ReplaceAll(service, "-", "_")] = object{"url": cloud.template(service, true), "id": "222"}
			}
			writeJSON(t, outputs, object{"database_maintenance_templates": object{"value": values}})
			code = database.Run(t.Context(), []string{"maintenance-replace", targets, outputs, evidence}, getenv, cloud.execute, &logs, &logs)
			require.NotContains(t, logs.String(), privateValue)
			require.NotContains(t, logs.String(), "sha256:")
			if slices.Contains([]string{"Success", "NumericTemplate", "ComputedFields", "BackupTag", "SameInstance"}, scenario) {
				expectCode(t, 0, code, logs.String())
				require.Equal(t, []string{"backup/json-keys", "restore/json-keys", "backup/authentication", "restore/authentication", "replace/json-keys", "replace/authentication"}, cloud.events)
				var proof []object
				require.NoError(t, json.Unmarshal([]byte(read(t, evidence)), &proof))
				require.Len(t, proof, 2)
				for _, host := range proof {
					require.Equal(t, "333", host["oldInstanceId"])
					id := "444"
					if scenario == "SameInstance" {
						id = "333"
					}
					require.Equal(t, id, host["newInstanceId"])
					require.Equal(t, "666", host["bootDiskId"])
					require.NotEmpty(t, host["restoreExecution"])
				}
				info, err := os.Stat(evidence)
				require.NoError(t, err)
				require.Equal(t, os.FileMode(0o600), info.Mode().Perm())
			} else {
				expectCode(t, 70, code, logs.String())
				require.NoFileExists(t, evidence)
				require.NotContains(t, cloud.events, "replace/authentication", "peer must remain untouched after failure")
				if slices.Contains([]string{"StaleSnapshot", "BackupFailure", "RestoreFailure", "MetadataDrift", "ChangedInstance", "TemplateReused", "TemplateChangedImage", "TemplateChangedScript"}, scenario) {
					require.NotContains(t, cloud.events, "replace/json-keys")
				}
			}
		})
	}
}

type maintenanceCloud struct {
	t            *testing.T
	dir          string
	env          map[string]string
	hosts        map[string]*databaseCloud
	scenario     string
	applied      bool
	events       []string
	imageUpdates map[string]map[string]string
}

func newMaintenanceCloud(t *testing.T) *maintenanceCloud {
	t.Helper()
	return &maintenanceCloud{t: t, dir: t.TempDir(), hosts: map[string]*databaseCloud{"json-keys": newDatabaseCloud(t, "json-keys"), "authentication": newDatabaseCloud(t, "authentication")}, env: map[string]string{
		"LEGACY_DATABASE_MAINTENANCE_ENABLED": "true", "PRODUCTION_RELEASES_ENABLED": "false", "GITHUB_REPOSITORY": "a-novel/infra",
		"GITHUB_REF": "refs/heads/master", "GITHUB_WORKFLOW_REF": "a-novel/infra/.github/workflows/foundation.yaml@refs/heads/master", "GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_SHA": strings.Repeat("a", 40),
	}}
}

func (cloud *maintenanceCloud) template(service string, updated bool) string {
	if cloud.imageUpdates[service] != nil {
		updated = false
	}
	version := "old"
	if updated {
		version = "new"
	}
	return "https://www.googleapis.com/compute/v1/projects/" + cloud.hosts[service].project + "/global/instanceTemplates/" + version + "-" + service
}

func (cloud *maintenanceCloud) plan(t *testing.T) object {
	t.Helper()
	var changes []object
	for _, service := range []string{"json-keys", "authentication"} {
		c := cloud.hosts[service]
		before := object{"project": c.project, "self_link": cloud.template(service, false), "numeric_id": "111", "machine_type": "e2-medium", "metadata_startup_script": "old-script"}
		after := maps.Clone(before)
		after["metadata_startup_script"] = "new-script"
		group := object{
			"project": c.project, "zone": c.zone, "name": "agora-database-" + service, "target_size": 1,
			"version":       []object{{"name": "primary", "target_size": []object{}}},
			"update_policy": []object{{"type": "OPPORTUNISTIC"}}, "stateful_disk": []object{{"device_name": "agora-data", "delete_rule": "NEVER"}},
			"stateful_internal_ip": []object{{"interface_name": "nic0", "delete_rule": "NEVER"}}, "all_instances_config": []object{{"metadata": c.metadata}},
		}
		key := `["` + strings.ReplaceAll(service, "-", "_") + `"]`
		changes = append(changes,
			object{"address": "google_compute_instance_template.database" + key, "mode": "managed", "change": object{"before": before, "after": after, "actions": []string{"create", "delete"}, "replace_paths": [][]string{{"metadata_startup_script"}}}},
			object{"address": "google_compute_instance_group_manager.database" + key, "mode": "managed", "change": object{"before": group, "after": maps.Clone(group), "actions": []string{"update"}}},
			object{"address": "google_compute_disk.database" + key, "mode": "managed", "change": object{"before": object{"disk_id": c.disk}, "actions": []string{"no-op"}}},
		)
	}
	return object{"format_version": "1.2", "resource_changes": changes}
}

func (cloud *maintenanceCloud) execute(ctx context.Context, output io.Writer, command string, args ...string) error {
	t := cloud.t
	t.Helper()
	require.Equal(t, "gcloud", command)
	service := "json-keys"
	if strings.Contains(strings.Join(args, " "), "authentication") {
		service = "authentication"
	}
	c := cloud.hosts[service]
	name := "agora-database-" + service + "-test"
	prefix := "https://www.googleapis.com/compute/v1/projects/" + c.project
	subnet := prefix + "/regions/europe-west1/subnetworks/agora-production-europe-west1"
	updated := c.writes > 0
	instanceID, script := "333", "old-script"
	if updated {
		instanceID, script = "444", "new-script"
	}
	imageUpdate := cloud.imageUpdates[service] != nil
	if imageUpdate {
		instanceID, script = "333", "old-script"
		if updated && cloud.scenario == "ReplacedInstance" {
			instanceID = "444"
		}
	}
	var value any
	metadata := maps.Clone(c.metadata)
	if cloud.scenario == "MetadataDrift" && cloud.applied {
		metadata[isolationRevision] = strings.Repeat("c", 40)
	}
	if cloud.scenario == "MissingMetadata" {
		delete(metadata, isolationRevision)
	}
	if (cloud.scenario == "SameInstance" && updated) || (cloud.scenario == "ChangedInstance" && cloud.applied) {
		instanceID = "333"
		if !updated {
			instanceID = "555"
		}
	}
	accounts := []object{{"email": "database@" + c.project + ".iam.gserviceaccount.com", "scopes": []string{"https://www.googleapis.com/auth/cloud-platform"}}}
	key := strings.Join(args[:3], " ")
	switch key {
	case "compute instance-templates describe":
		isNew := strings.HasPrefix(args[3], "new-")
		id, startup, machine := "111", "old-script", "e2-medium"
		if isNew {
			id, startup = "222", "new-script"
		}
		if (cloud.scenario == "PriorTemplateReused" && !isNew) || (cloud.scenario == "TemplateReused" && isNew) {
			id = "999"
		}
		if cloud.scenario == "TemplateChangedImage" && isNew {
			machine = "e2-standard-4"
		}
		if cloud.scenario == "TemplateChangedScript" && isNew {
			startup = "unreviewed"
		}
		value = object{"id": id, "selfLink": cloud.template(service, isNew), "properties": object{"machineType": machine, "serviceAccounts": accounts, "networkInterfaces": []object{{"subnetwork": subnet}}, "metadata": object{"fingerprint": id, "items": []object{{"key": "startup-script", "value": startup}}}}}
	case "compute instance-groups managed":
		switch args[3] {
		case "describe":
			if imageUpdate && cloud.applied && cloud.scenario != "GroupMetadataDrift" {
				metadata = cloud.imageUpdates[service]
			}
			policy := object{"type": "OPPORTUNISTIC", "replacementMethod": "RECREATE", "minimalAction": "REPLACE", "mostDisruptiveAllowedAction": "REPLACE", "maxSurge": object{"fixed": 0}, "maxUnavailable": object{"fixed": 1}}
			state := object{"disks": object{"agora-data": object{"autoDelete": "NEVER"}}, "internalIPs": object{"nic0": object{"autoDelete": "NEVER"}}}
			if cloud.scenario == "PreservationDisabled" {
				nested(state, "disks", "agora-data")["autoDelete"] = "ON_PERMANENT_INSTANCE_DELETION"
			}
			if cloud.scenario == "WrongPreservedDisk" {
				state["disks"] = object{"other-data": object{"autoDelete": "NEVER"}}
			}
			if cloud.scenario == "WrongPreservedIP" {
				state["internalIPs"] = object{"nic1": object{"autoDelete": "NEVER"}}
			}
			if cloud.scenario == "ProactiveGroup" {
				policy["type"] = "PROACTIVE"
			}
			if cloud.scenario == "Surge" {
				nested(policy, "maxSurge")["fixed"] = 1
			}
			value = object{"name": "agora-database-" + service, "targetSize": 1, "status": object{"isStable": cloud.scenario != "UnstableGroup"}, "versions": []object{{"name": "primary", "instanceTemplate": cloud.template(service, cloud.applied)}}, "statefulPolicy": object{"preservedState": state}, "updatePolicy": policy, "allInstancesConfig": object{"properties": object{"metadata": metadata}}}
		case "list-instances":
			if slices.Contains(args, "--format=value(instance.basename())") {
				return c.execute(ctx, output, command, args...)
			}
			template := cloud.template(service, updated)
			if cloud.scenario == "WrongAdoptedTemplate" && updated {
				template = cloud.template(service, false)
			}
			if cloud.scenario == "NumericTemplate" {
				template = prefix + "/global/instanceTemplates/111"
				if updated {
					template = prefix + "/global/instanceTemplates/222"
				}
			}
			member := object{"instance": prefix + "/zones/" + c.zone + "/instances/" + name, "id": instanceID, "currentAction": "NONE", "instanceStatus": "RUNNING", "version": object{"instanceTemplate": template}}
			if cloud.scenario == "BusyMember" {
				member["currentAction"] = "RECREATING"
			}
			value = []object{member}
			if cloud.scenario == "MultipleMembers" {
				value = []object{member, member}
			}
		case "update-instances":
			action := "replace"
			if imageUpdate {
				action = "restart"
			}
			require.Equal(t, []string{"--instances=" + name, "--minimal-action=" + action, "--most-disruptive-allowed-action=" + action, "--quiet", "--project=" + c.project, "--zone=" + c.zone}, args[5:])
			cloud.events = append(cloud.events, action+"/"+service)
			if cloud.scenario == "ReplaceFailure" {
				return errors.New(privateValue)
			}
			c.writes++
			if imageUpdate && cloud.scenario != "MemberMetadataDrift" {
				c.metadata = maps.Clone(cloud.imageUpdates[service])
			}
			return nil
		case "wait-until":
			return c.execute(ctx, output, command, args...)
		default:
			t.Fatalf("unexpected maintenance mutation: %v", args)
		}
	case "compute instances describe":
		if slices.Contains(args, "--format=value(lastStartTimestamp)") {
			at := time.Now().Add(-20 * time.Minute)
			if cloud.scenario == "OutsideInterval" {
				at = time.Now().Add(-2 * time.Hour)
			}
			_, err := fmt.Fprintln(output, at.Format(time.RFC3339))
			return err
		}
		items := []object{{"key": "startup-script", "value": script}}
		for key, value := range metadata {
			items = append(items, object{"key": key, "value": value})
		}
		disk := object{"boot": false, "deviceName": "agora-data", "autoDelete": false, "mode": "READ_WRITE", "source": prefix + "/zones/" + c.zone + "/disks/agora-data-" + service}
		nic := object{"name": "nic0", "networkIP": "10.20.0.2", "subnetwork": subnet}
		if cloud.scenario == "PublicAddress" {
			nic["accessConfigs"] = []object{{"natIP": "1.2.3.4"}}
		}
		if cloud.scenario == "DiskAutoDelete" {
			disk["autoDelete"] = true
		}
		if cloud.scenario == "AddressDrift" && updated {
			nic["networkIP"] = "10.20.0.3"
		}
		if cloud.scenario == "WrongRuntime" && updated {
			accounts[0]["email"] = "peer@" + c.project + ".iam.gserviceaccount.com"
		}
		if cloud.scenario == "WrongLiveScript" && updated {
			items[0]["value"] = "unreviewed"
		}
		value = object{"name": name, "id": instanceID, "status": "RUNNING", "machineType": prefix + "/zones/" + c.zone + "/machineTypes/e2-medium", "serviceAccounts": accounts, "metadata": object{"items": items}, "networkInterfaces": []object{nic}, "disks": []object{{"boot": true, "autoDelete": true, "deviceName": "agora-boot", "source": prefix + "/zones/" + c.zone + "/disks/" + name}, disk}}
	case "compute disks describe":
		if args[3] != name {
			return c.execute(ctx, output, command, args...)
		}
		id, created := "555", time.Now().Add(-24*time.Hour)
		if updated {
			id, created = "666", time.Now().Add(-20*time.Minute)
			if cloud.scenario == "SameBootDisk" {
				id = "555"
			}
			if cloud.scenario == "OutsideInterval" {
				created = time.Now().Add(-24 * time.Hour)
			}
		}
		if imageUpdate && cloud.scenario != "ReplacedBootDisk" {
			id = "555"
		}
		value = object{"id": id, "selfLink": prefix + "/zones/" + c.zone + "/disks/" + name, "status": "READY", "creationTimestamp": created.Format(time.RFC3339), "users": []string{prefix + "/zones/" + c.zone + "/instances/" + name}}
		if cloud.scenario == "InvalidBootDisk" && updated {
			value.(object)["users"] = []string{"other-instance"}
		}
	case "run jobs execute":
		kind := "backup"
		if strings.Contains(args[3], "restore") {
			kind = "restore"
		}
		require.Equal(t, []string{"--project=" + c.project, "--region=europe-west1", "--wait", "--quiet", "--format=value(metadata.name)"}, args[4:])
		cloud.events = append(cloud.events, kind+"/"+service)
		if (cloud.scenario == "BackupFailure" && kind == "backup") || (cloud.scenario == "RestoreFailure" && kind == "restore" && service == "authentication") {
			return errors.New(privateValue)
		}
		_, err := fmt.Fprintln(output, args[3]+"-test")
		return err
	default:
		if cloud.scenario == "StaleSnapshot" {
			c.snapshot["creationTimestamp"] = "2000-01-01T00:00:00Z"
		}
		if imageUpdate && updated && cloud.scenario == "MemberMetadataDrift" {
			c.statuses = []string{"healthy:" + cloud.imageUpdates[service][isolationRevision] + ":22222222-2222-2222-2222-222222222222"}
		}
		if cloud.scenario == "UnhealthySource" || (cloud.scenario == "ReadinessFailure" && updated) {
			c.statuses = []string{"failed:" + c.metadata[isolationRevision] + ":11111111-1111-1111-1111-111111111111"}
			if updated {
				c.statuses[0] = strings.ReplaceAll(c.statuses[0], "11111111", "22222222")
			}
		}
		return c.execute(ctx, output, command, args...)
	}
	return json.NewEncoder(output).Encode(value)
}
