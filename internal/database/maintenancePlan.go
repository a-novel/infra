package database

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"maps"
	"os"
	"reflect"
	"strings"

	"google.golang.org/api/compute/v1"
)

type maintenanceTarget struct {
	Project, Zone, Service, DiskID, Template, Startup string
	TemplateID, ReplacementID                         string
	Instance, InstanceID, Address, Boot               string
	BootDiskID                                        string
	Metadata                                          map[string]string
	DesiredMetadata                                   map[string]string `json:",omitempty"`
	Properties                                        *compute.InstanceProperties
}

func maintenanceEnabled(getenv func(string) string) bool {
	return getenv("LEGACY_DATABASE_MAINTENANCE_ENABLED") == "true" && getenv("PRODUCTION_RELEASES_ENABLED") == "false" &&
		getenv("GITHUB_REPOSITORY") == "a-novel/infra" && getenv("GITHUB_REF") == "refs/heads/master" &&
		getenv("GITHUB_WORKFLOW_REF") == "a-novel/infra/.github/workflows/foundation.yaml@refs/heads/master" &&
		getenv("GITHUB_EVENT_NAME") == "workflow_dispatch" && matches(`[a-f0-9]{40}`, getenv("GITHUB_SHA"))
}

func maintenancePlan(ctx context.Context, args []string, getenv func(string) string, execute func(context.Context, io.Writer, string, ...string) error) error {
	if len(args) != 3 {
		return failure{64, "maintenance-plan requires private plan, inputs and target files"}
	}
	plan, err := read(args[0])
	if err != nil || !strings.HasPrefix(text(plan, "format_version"), "1.") {
		return failure{65, "maintenance requires a readable reviewed plan"}
	}
	config, err := read(args[1])
	if err != nil {
		return err
	}
	changes, ok := get(plan, "resource_changes").([]any)
	if !ok {
		return failure{65, "reviewed plan has no resource inventory"}
	}
	byAddress := map[string]object{}
	for _, value := range changes {
		change, ok := value.(object)
		if !ok || byAddress[text(change, "address")] != nil {
			return failure{65, "invalid or duplicate planned resource"}
		}
		byAddress[text(change, "address")] = change
	}
	var targets []maintenanceTarget
	allowed := map[string]bool{}
	for _, service := range []string{"json-keys", "authentication"} {
		key := `["` + strings.ReplaceAll(service, "-", "_") + `"]`
		address := "google_compute_instance_template.database" + key
		change := byAddress[address]
		groupAddress := "google_compute_instance_group_manager.database" + key
		group := byAddress[groupAddress]
		disk := byAddress["google_compute_disk.database"+key]
		if reflect.DeepEqual(get(change, "change", "actions"), []any{"no-op"}) &&
			get(group, "change", "before") != nil && !reflect.DeepEqual(get(group, "change", "actions"), []any{"no-op"}) && !protectionOnly(group) {
			if !maintenanceEnabled(getenv) || get(config, "native_backups", service, "wal_archiving") != true {
				return failure{77, "database image maintenance requires protected activation and paused releases"}
			}
			target, err := imageMaintenanceTarget(config, change, group, disk)
			if err != nil {
				return err
			}
			targets = append(targets, target)
			allowed[groupAddress] = true
			continue
		}
		if get(change, "change", "before") == nil || reflect.DeepEqual(get(change, "change", "actions"), []any{"no-op"}) {
			continue
		}
		if !maintenanceEnabled(getenv) || get(config, "native_backups", service, "wal_archiving") != true {
			return failure{77, "native backup maintenance is disabled or releases are not explicitly paused"}
		}
		if !reflect.DeepEqual(get(change, "change", "actions"), []any{"create", "delete"}) ||
			!reflect.DeepEqual(get(change, "change", "replace_paths"), []any{[]any{"metadata_startup_script"}}) {
			return failure{65, "maintenance permits only startup-script template replacement"}
		}
		before, _ := get(change, "change", "before").(object)
		after, _ := get(change, "change", "after").(object)
		before = maps.Clone(before)
		delete(before, "metadata_startup_script")
		after = maps.Clone(after)
		delete(after, "metadata_startup_script")
		if !sameKnown(before, after, get(change, "change", "after_unknown")) {
			return failure{65, "template changes exceed the startup script"}
		}
		h := host{project: text(config, "workload_project_id"), zone: text(config, "database_zone"), service: service, execute: execute}
		h.disk = text(disk, "change", "before", "disk_id")
		oldGroup, _ := get(group, "change", "before").(object)
		newGroup, _ := get(group, "change", "after").(object)
		if !sameKnown(oldGroup["version"], newGroup["version"], get(group, "change", "after_unknown", "version")) {
			return failure{65, "maintenance group version changed beyond its pending template"}
		}
		oldGroup, newGroup = maps.Clone(oldGroup), maps.Clone(newGroup)
		delete(oldGroup, "version")
		delete(newGroup, "version")
		var oldMetadata, desiredMetadata map[string]string
		if !reflect.DeepEqual(oldGroup["all_instances_config"], newGroup["all_instances_config"]) {
			oldMetadata, desiredMetadata = plannedMetadata(oldGroup), plannedMetadata(newGroup)
			if !h.backupCredentialRetirement(oldMetadata, desiredMetadata) {
				return failure{65, "startup maintenance may only retire the obsolete backup password reference"}
			}
			oldConfig := maps.Clone(oldGroup["all_instances_config"].([]any)[0].(object))
			oldConfig["metadata"] = get(newGroup, "all_instances_config").([]any)[0].(object)["metadata"]
			oldGroup["all_instances_config"] = []any{oldConfig}
		}
		for _, field := range []string{"project", "zone", "name", "target_size", "update_policy", "stateful_disk", "stateful_internal_ip", "all_instances_config"} {
			if oldGroup[field] == nil || !reflect.DeepEqual(oldGroup[field], newGroup[field]) {
				return failure{65, "reviewed group preservation policy or release metadata changed"}
			}
		}
		if !matches(`[a-z][a-z0-9-]{4,28}[a-z0-9]`, h.project) || !matches(`[a-z]+-[a-z]+[0-9]+-[a-z]`, h.zone) ||
			!matches(`[1-9][0-9]*`, h.disk) || text(before, "project") != h.project || text(oldGroup, "project") != h.project ||
			text(oldGroup, "zone") != h.zone || text(oldGroup, "name") != h.group() ||
			!reflect.DeepEqual(get(disk, "change", "actions"), []any{"no-op"}) ||
			!reflect.DeepEqual(get(group, "change", "actions"), []any{"update"}) ||
			!sameKnown(oldGroup, newGroup, get(group, "change", "after_unknown")) {
			return failure{65, "maintenance requires unchanged singleton groups and data disks"}
		}
		target := maintenanceTarget{
			Project: h.project, Zone: h.zone, Service: service, DiskID: h.disk,
			Template: text(before, "self_link"), TemplateID: text(before, "numeric_id"), Startup: text(change, "change", "after", "metadata_startup_script"),
			Metadata: oldMetadata, DesiredMetadata: desiredMetadata,
		}
		if target.Startup == "" || !validTemplate(target.Template, h.project) || !matches(`[1-9][0-9]*`, target.TemplateID) {
			return failure{65, "reviewed template identity or startup script is missing"}
		}
		targets = append(targets, target)
		allowed[address], allowed[groupAddress] = true, true
		bindingAddress := "google_compute_instance_template_iam_member.database_release" + key
		if binding := byAddress[bindingAddress]; binding != nil &&
			!sameKnown(get(binding, "change", "before"), get(binding, "change", "after"), get(binding, "change", "after_unknown")) {
			return failure{65, "maintenance template release permission changed"}
		}
		allowed[bindingAddress] = true
	}
	if len(targets) > 0 {
		for address, change := range byAddress {
			if text(change, "mode") == "data" || reflect.DeepEqual(get(change, "change", "actions"), []any{"no-op"}) {
				continue
			}
			if !allowed[address] {
				return failure{65, "maintenance plan contains unrelated managed-resource changes"}
			}
		}
		for index := range targets {
			expected := targets[index].Metadata
			if err := targets[index].capture(ctx, execute); err != nil {
				return err
			}
			if expected != nil && !maps.Equal(expected, targets[index].Metadata) {
				return failure{70, "live database release differs from the reviewed plan"}
			}
			if targets[index].DesiredMetadata != nil && targets[index].Startup == startupScript(targets[index].Properties.Metadata) && len(targets) != 1 {
				return failure{65, "review one database image transition separately from other maintenance"}
			}
		}
	} else {
		for address, change := range byAddress {
			if (strings.HasPrefix(address, "google_compute_instance_group_manager.database[") || strings.HasPrefix(address, "google_compute_disk.database[")) &&
				get(change, "change", "before") != nil && !reflect.DeepEqual(get(change, "change", "actions"), []any{"no-op"}) && !protectionOnly(change) {
				return failure{65, "existing database host changes require separate maintenance review"}
			}
		}
	}
	data, err := json.Marshal(targets)
	if err != nil {
		return err
	}
	return os.WriteFile(args[2], data, 0o600)
}

// Protection-only updates change provider bookkeeping, not the running host.
// Require a fully known, exact strengthening; combined changes remain maintenance.
func protectionOnly(resource object) bool {
	before, _ := get(resource, "change", "before").(object)
	after, _ := get(resource, "change", "after").(object)
	unknown, _ := get(resource, "change", "after_unknown").(object)
	if !reflect.DeepEqual(get(resource, "change", "actions"), []any{"update"}) ||
		before["deletion_policy"] != "DELETE" || after["deletion_policy"] != "PREVENT" ||
		unknown == nil || len(unknown) != 0 {
		return false
	}
	before = maps.Clone(before)
	before["deletion_policy"] = "PREVENT"
	return reflect.DeepEqual(before, after)
}

func (h host) backupCredentialRetirement(before, after map[string]string) bool {
	withoutBackup := maps.Clone(before)
	delete(withoutBackup, "agora-"+h.service+"-postgres-backup-password-version")
	return h.validRelease(before) && h.validRelease(after) && len(before) == 4 && len(after) == 3 && maps.Equal(withoutBackup, after)
}

// Provider-computed values are checked against the actual templates before any
// replacement. Known changes must be confined to the explicitly removed fields.
func sameKnown(before, after, unknown any) bool {
	if unknown == true {
		return true
	}
	// The provider records empty optional attributes in state but plans null.
	if after == nil {
		switch value := before.(type) {
		case string:
			return value == ""
		case json.Number:
			return value.String() == "0"
		case object:
			return len(value) == 0
		case []any:
			return len(value) == 0
		}
	}
	switch value := after.(type) {
	case object:
		old, ok := before.(object)
		if !ok {
			return false
		}
		mask, _ := unknown.(object)
		for key := range old {
			if _, present := value[key]; !present && mask[key] != true {
				return false
			}
		}
		for key, item := range value {
			if !sameKnown(old[key], item, mask[key]) {
				return false
			}
		}
		return true
	case []any:
		old, ok := before.([]any)
		if !ok || len(old) != len(value) {
			return false
		}
		mask, _ := unknown.([]any)
		for index, item := range value {
			var pending any
			if index < len(mask) {
				pending = mask[index]
			}
			if !sameKnown(old[index], item, pending) {
				return false
			}
		}
		return true
	case string:
		old, ok := before.(string)
		return ok && strings.TrimPrefix(old, "https://www.googleapis.com/compute/v1/") == strings.TrimPrefix(value, "https://www.googleapis.com/compute/v1/")
	default:
		return reflect.DeepEqual(before, after)
	}
}

func validTemplate(value, project string) bool {
	return matches(`https://www[.]googleapis[.]com/compute/v1/projects/`+project+`/global/instanceTemplates/[a-z0-9-]+`, value)
}

func privateJSON(path string, value any) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	if json.Unmarshal(data, value) != nil {
		return errors.New("private maintenance document is invalid")
	}
	return nil
}
