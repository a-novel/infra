package database

import (
	"context"
	"encoding/json"
	"io"
	"maps"
	"os"
	"reflect"
	"strconv"
	"strings"
	"time"
)

// imageMaintenanceTarget admits an image-only change under the existing saved-plan hold.
func imageMaintenanceTarget(config, template, group, disk object) (maintenanceTarget, error) {
	invalid := failure{65, "image maintenance requires an unchanged host, disk, credentials and template"}
	before, _ := get(group, "change", "before").(object)
	after, _ := get(group, "change", "after").(object)
	oldMetadata, newMetadata := plannedMetadata(before), plannedMetadata(after)
	service := strings.TrimPrefix(text(before, "name"), "agora-database-")
	h := host{project: text(config, "workload_project_id"), zone: text(config, "database_zone"), service: service, disk: text(disk, "change", "before", "disk_id")}
	if (service != "json-keys" && service != "authentication") || !matches(`[1-9][0-9]*`, h.disk) ||
		!matches(`[a-z]+-[a-z]+[0-9]+-[a-z]`, h.zone) || !matches(`[a-z][a-z0-9-]{4,28}[a-z0-9]`, h.project) ||
		text(before, "project") != h.project || text(before, "zone") != h.zone ||
		!h.validRelease(oldMetadata) || !h.validRelease(newMetadata) ||
		oldMetadata[revisionKey] == newMetadata[revisionKey] ||
		oldMetadata["agora-"+service+"-database-image"] == newMetadata["agora-"+service+"-database-image"] ||
		oldMetadata["agora-"+service+"-postgres-password-version"] != newMetadata["agora-"+service+"-postgres-password-version"] ||
		oldMetadata["agora-"+service+"-postgres-backup-password-version"] != newMetadata["agora-"+service+"-postgres-backup-password-version"] ||
		!reflect.DeepEqual(get(group, "change", "actions"), []any{"update"}) ||
		!reflect.DeepEqual(get(disk, "change", "actions"), []any{"no-op"}) ||
		!reflect.DeepEqual(get(template, "change", "actions"), []any{"no-op"}) {
		return maintenanceTarget{}, invalid
	}
	for _, field := range []string{"name", "target_size", "version", "update_policy", "stateful_disk", "stateful_internal_ip"} {
		if before[field] == nil || !reflect.DeepEqual(before[field], after[field]) {
			return maintenanceTarget{}, invalid
		}
	}
	before, after = maps.Clone(before), maps.Clone(after)
	oldConfig := maps.Clone(before["all_instances_config"].([]any)[0].(object))
	newConfig := maps.Clone(after["all_instances_config"].([]any)[0].(object))
	delete(oldConfig, "metadata")
	delete(newConfig, "metadata")
	if !reflect.DeepEqual(oldConfig, newConfig) {
		return maintenanceTarget{}, invalid
	}
	delete(before, "all_instances_config")
	delete(after, "all_instances_config")
	if !sameKnown(before, after, get(group, "change", "after_unknown")) {
		return maintenanceTarget{}, invalid
	}
	target := maintenanceTarget{
		Project: h.project, Zone: h.zone, Service: service, DiskID: h.disk,
		Template: text(template, "change", "before", "self_link"), TemplateID: text(template, "change", "before", "numeric_id"),
		Startup: text(template, "change", "before", "metadata_startup_script"), Metadata: oldMetadata, DesiredMetadata: newMetadata,
	}
	if target.Startup == "" || !validTemplate(target.Template, h.project) || !matches(`[1-9][0-9]*`, target.TemplateID) {
		return maintenanceTarget{}, invalid
	}
	return target, nil
}

func plannedMetadata(group object) map[string]string {
	configs, _ := group["all_instances_config"].([]any)
	if len(configs) != 1 {
		return nil
	}
	fields, _ := get(configs[0], "metadata").(object)
	result := make(map[string]string, len(fields))
	for key, value := range fields {
		text, ok := value.(string)
		if !ok {
			return nil
		}
		result[key] = text
	}
	return result
}

// restartImage applies the reviewed MIG metadata with Google's restart-only ceiling.
// Recovery only attests an already completed restart; it never replays a mutation.
func (target maintenanceTarget) restartImage(ctx context.Context, execute func(context.Context, io.Writer, string, ...string) error, evidence string, recovery bool, started, finished time.Time) error {
	h := target.host(execute)
	if !h.validRelease(target.Metadata) || !h.validRelease(target.DesiredMetadata) || target.BootDiskID == "" || target.InstanceID == "" || target.Address == "" || target.Properties == nil {
		return failure{65, "image maintenance target is incomplete"}
	}
	record := object{"service": target.Service, "diskId": target.DiskID, "privateAddress": target.Address, "oldInstanceId": target.InstanceID, "template": target.Template, "templateId": target.TemplateID}
	if !recovery {
		if err := target.verifyImageHost(ctx, execute, false); err != nil {
			return err
		}
		if err := h.snapshot(ctx); err != nil {
			return err
		}
		for _, kind := range []string{"backup", "restore"} {
			job := "agora-postgres-" + kind + "-" + target.Service
			name, err := h.command(ctx, "run", "jobs", "execute", job, "--project="+h.project, "--region="+h.region(), "--wait", "--quiet", "--format=value(metadata.name)")
			if err != nil || !matches(job+`-[a-z0-9]+`, name) {
				return failure{70, "required backup or clean restore check failed; no host restarted"}
			}
			record[kind+"Execution"] = name
		}
		if err := target.verifyImageHost(ctx, execute, false); err != nil {
			return err
		}
		for _, step := range [][]string{
			{"update-instances", h.group(), "--instances=" + target.Instance, "--minimal-action=restart", "--most-disruptive-allowed-action=restart", "--quiet"},
			{"wait-until", h.group(), "--stable", "--timeout=600", "--quiet"},
		} {
			if _, err := h.compute(ctx, append([]string{"instance-groups", "managed"}, step...)...); err != nil {
				return failure{70, "database restart outcome is uncertain; retain the maintenance hold"}
			}
		}
		if err := h.wait(ctx, target.DesiredMetadata[revisionKey], target.Boot); err != nil {
			return err
		}
	}
	if err := target.verifyImageHost(ctx, execute, true); err != nil {
		return err
	}
	if recovery {
		data, err := h.compute(ctx, "instances", "describe", target.Instance, "--format=value(lastStartTimestamp)")
		at, parseErr := time.Parse(time.RFC3339Nano, data)
		if err != nil || parseErr != nil || at.Before(started) || at.After(finished) {
			return failure{70, "restart during the original maintenance interval is unconfirmed"}
		}
		record["reconciled"] = true
	}
	record["newInstanceId"], record["bootDiskId"] = target.InstanceID, target.BootDiskID
	record["completedAt"] = time.Now().UTC().Format(time.RFC3339)
	data, err := json.Marshal([]object{record})
	if err != nil {
		return err
	}
	return os.WriteFile(evidence, data, 0o600)
}

// verifyImageHost checks applied group metadata independently from the running member.
func (target maintenanceTarget) verifyImageHost(ctx context.Context, execute func(context.Context, io.Writer, string, ...string) error, completed bool) error {
	if completed {
		target.Metadata = target.DesiredMetadata
	}
	instance, err := target.observe(ctx, execute, target.Template, target.Template, target.DesiredMetadata)
	if err != nil || strconv.FormatUint(instance.Id, 10) != target.InstanceID {
		return failure{70, "database image maintenance changed the host or its reviewed configuration"}
	}
	disk, err := target.bootDisk(ctx, execute, instance)
	if err != nil || strconv.FormatUint(disk.Id, 10) != target.BootDiskID {
		return failure{70, "image maintenance requires the original boot and data disks"}
	}
	boot, err := target.host(execute).current(ctx)
	if err != nil || (!completed && boot != target.Boot) || (completed && (boot == target.Boot || !strings.HasPrefix(boot, "healthy:"+target.DesiredMetadata[revisionKey]+":"))) {
		return failure{70, "database image maintenance boot health is unconfirmed"}
	}
	return nil
}
