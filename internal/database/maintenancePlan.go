package database

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"maps"
	"os"
	"reflect"
	"slices"
	"strings"

	"google.golang.org/api/compute/v1"
)

type maintenanceTarget struct {
	Project, Zone, Service, DiskID, Template, Startup string
	TemplateID, ReplacementID                         string
	Instance, InstanceID, Address, Boot               string
	Metadata                                          map[string]string
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
		if get(change, "change", "before") == nil || reflect.DeepEqual(get(change, "change", "actions"), []any{"no-op"}) {
			continue
		}
		if !maintenanceEnabled(getenv) || get(config, "legacy_backup_job_access") != true {
			return failure{77, "Legacy host maintenance is disabled or releases are not explicitly paused."}
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
		disk := byAddress["google_compute_disk.database"+key]
		h.disk = text(disk, "change", "before", "disk_id")
		groupAddress := "google_compute_instance_group_manager.database" + key
		group := byAddress[groupAddress]
		oldGroup, _ := get(group, "change", "before").(object)
		newGroup, _ := get(group, "change", "after").(object)
		if !sameKnown(oldGroup["version"], newGroup["version"], get(group, "change", "after_unknown", "version")) {
			return failure{65, "maintenance group version changed beyond its pending template"}
		}
		oldGroup, newGroup = maps.Clone(oldGroup), maps.Clone(newGroup)
		delete(oldGroup, "version")
		delete(newGroup, "version")
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
		additions := []string{
			"google_project_iam_custom_role.foundation_backup_jobs[0]", "google_project_iam_member.foundation_backup_jobs[0]",
			"google_project_iam_custom_role.foundation_backup_observation[0]", "google_project_iam_member.foundation_backup_observation[0]",
			"google_project_iam_custom_role.foundation_backup_tagging[0]", "google_project_iam_member.foundation_backup_tagging[0]",
			"google_tags_tag_key.legacy_backup[0]", "google_tags_tag_value.legacy_backup[0]", "google_tags_tag_value_iam_member.foundation_backup_tag[0]",
		}
		for _, job := range []string{"agora-postgres-backup-json-keys", "agora-postgres-restore-json-keys", "agora-postgres-backup-authentication", "agora-postgres-restore-authentication", "agora-postgres-backup-monitor"} {
			address := `google_tags_location_tag_binding.legacy_backup["` + job + `"]`
			if change := byAddress[address]; change != nil && !reflect.DeepEqual(get(change, "change", "actions"), []any{"no-op"}) {
				h := targets[0].host(execute)
				parent := "//run.googleapis.com/projects/" + h.project + "/locations/" + h.region() + "/jobs/" + job
				if text(change, "change", "after", "parent") != parent || text(change, "change", "after", "location") != h.region() {
					return failure{65, "backup tag attachment has an unexpected job or region"}
				}
			}
			additions = append(additions, address)
		}
		for address, change := range byAddress {
			if text(change, "mode") == "data" || reflect.DeepEqual(get(change, "change", "actions"), []any{"no-op"}) {
				continue
			}
			permission := slices.Contains(additions, address) && reflect.DeepEqual(get(change, "change", "actions"), []any{"create"})
			if !allowed[address] && !permission {
				return failure{65, "maintenance plan contains unrelated managed-resource changes"}
			}
		}
		for index := range targets {
			if err := targets[index].capture(ctx, execute); err != nil {
				return err
			}
		}
	} else {
		for address, change := range byAddress {
			if (strings.HasPrefix(address, "google_compute_instance_group_manager.database[") || strings.HasPrefix(address, "google_compute_disk.database[")) &&
				get(change, "change", "before") != nil && !reflect.DeepEqual(get(change, "change", "actions"), []any{"no-op"}) {
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
