package database

import (
	"context"
	"encoding/json"
	"io"
	"maps"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strconv"
	"strings"
	"time"

	"google.golang.org/api/compute/v1"
)

func (target maintenanceTarget) host(execute func(context.Context, io.Writer, string, ...string) error) host {
	return host{target.Project, target.Zone, target.Service, target.DiskID, execute}
}

func (target *maintenanceTarget) capture(ctx context.Context, execute func(context.Context, io.Writer, string, ...string) error) error {
	h := target.host(execute)
	metadata, err := h.liveMetadata(ctx)
	if err != nil || !h.validRelease(metadata) {
		return failure{70, "maintenance requires an initialized database release"}
	}
	target.Metadata = metadata
	template, err := h.template(ctx, target.Template)
	if err != nil || strconv.FormatUint(template.Id, 10) != target.TemplateID {
		return failure{70, "reviewed prior template incarnation changed"}
	}
	target.Properties = template.Properties
	instance, err := target.observe(ctx, execute, target.Template, target.Template)
	if err != nil {
		return err
	}
	target.Instance, target.InstanceID = instance.Name, strconv.FormatUint(instance.Id, 10)
	target.Address = instance.NetworkInterfaces[0].NetworkIP
	target.Boot, err = h.current(ctx)
	if err != nil || !strings.HasPrefix(target.Boot, "healthy:"+metadata[revisionKey]+":") {
		return failure{70, "maintenance requires the current database to be healthy"}
	}
	return nil
}

func (h host) template(ctx context.Context, name string) (*compute.InstanceTemplate, error) {
	if !validTemplate(name, h.project) {
		return nil, failure{65, "invalid maintenance template"}
	}
	data, err := h.command(ctx, "compute", "instance-templates", "describe", filepath.Base(name), "--project="+h.project, "--format=json")
	var template compute.InstanceTemplate
	if err != nil || json.Unmarshal([]byte(data), &template) != nil || template.SelfLink != name || template.Id == 0 || template.Properties == nil {
		return nil, failure{70, "maintenance template is unconfirmed"}
	}
	return &template, nil
}

// observe fences each mutation with the singleton's preserved state and exact
// release metadata. The group may target the new template while its member does not.
func (target maintenanceTarget) observe(ctx context.Context, execute func(context.Context, io.Writer, string, ...string) error, groupTemplate, memberTemplate string) (*compute.Instance, error) {
	h := target.host(execute)
	if err := h.checkDisk(ctx); err != nil {
		return nil, err
	}
	data, err := h.compute(ctx, "instance-groups", "managed", "describe", h.group(), "--format=json")
	var group compute.InstanceGroupManager
	if err != nil || json.Unmarshal([]byte(data), &group) != nil || group.Name != h.group() || group.TargetSize != 1 ||
		len(group.Versions) != 1 || !target.matchesTemplate(group.Versions[0].InstanceTemplate, groupTemplate) || group.Versions[0].Name != "primary" ||
		group.StatefulPolicy == nil || group.StatefulPolicy.PreservedState == nil || group.UpdatePolicy == nil ||
		group.AllInstancesConfig == nil || group.AllInstancesConfig.Properties == nil {
		return nil, failure{70, "maintenance group identity or stateful policy is unconfirmed"}
	}
	policy, state := group.UpdatePolicy, group.StatefulPolicy.PreservedState
	if policy.Type != "OPPORTUNISTIC" || policy.ReplacementMethod != "RECREATE" || policy.MinimalAction != "REPLACE" ||
		policy.MostDisruptiveAllowedAction != "REPLACE" || policy.MaxSurge == nil || policy.MaxSurge.Fixed != 0 || policy.MaxSurge.Percent != 0 ||
		policy.MaxUnavailable == nil || policy.MaxUnavailable.Fixed != 1 || policy.MaxUnavailable.Percent != 0 ||
		len(state.Disks) != 1 || state.Disks["agora-data"].AutoDelete != "NEVER" ||
		len(state.InternalIPs) != 1 || state.InternalIPs["nic0"].AutoDelete != "NEVER" || len(state.ExternalIPs) != 0 {
		return nil, failure{70, "maintenance requires no-surge RECREATE with disk and address preservation"}
	}
	metadata, err := h.liveMetadata(ctx)
	if err != nil || !maps.Equal(metadata, target.Metadata) {
		return nil, failure{70, "release metadata changed during maintenance"}
	}
	data, err = h.compute(ctx, "instance-groups", "managed", "list-instances", h.group(), "--format=json")
	var members []compute.ManagedInstance
	if err != nil || json.Unmarshal([]byte(data), &members) != nil || len(members) != 1 || members[0].Version == nil ||
		members[0].CurrentAction != "NONE" || members[0].InstanceStatus != "RUNNING" || !target.matchesTemplate(members[0].Version.InstanceTemplate, memberTemplate) {
		return nil, failure{70, "maintenance member is busy or uses an unexpected template"}
	}
	member := members[0]
	name := filepath.Base(member.Instance)
	prefix := "https://www.googleapis.com/compute/v1/projects/" + h.project + "/zones/" + h.zone
	if !matches(h.group()+`-[a-z0-9]+`, name) || member.Instance != prefix+"/instances/"+name || member.Id == 0 ||
		(target.Instance != "" && target.Instance != name) {
		return nil, failure{70, "maintenance requires the exact generated singleton"}
	}
	data, err = h.compute(ctx, "instances", "describe", name, "--format=json")
	var instance compute.Instance
	if err != nil || json.Unmarshal([]byte(data), &instance) != nil || instance.Name != name || instance.Id != member.Id || instance.Status != "RUNNING" ||
		len(instance.Disks) != 2 || len(instance.NetworkInterfaces) != 1 || instance.Metadata == nil {
		return nil, failure{70, "maintenance instance identity or disk inventory is unconfirmed"}
	}
	diskSeen, bootSeen := false, false
	for _, disk := range instance.Disks {
		if disk.Boot {
			bootSeen = disk.AutoDelete && disk.DeviceName == "agora-boot"
		} else {
			diskSeen = !disk.AutoDelete && disk.DeviceName == "agora-data" && disk.Mode == "READ_WRITE" && disk.Source == prefix+"/disks/agora-data-"+h.service
		}
	}
	nic := instance.NetworkInterfaces[0]
	if !diskSeen || !bootSeen || nic.Name != "nic0" || nic.NetworkIP == "" || len(nic.AccessConfigs) != 0 || len(nic.Ipv6AccessConfigs) != 0 ||
		(target.Address != "" && nic.NetworkIP != target.Address) {
		return nil, failure{70, "maintenance data disk or private address changed"}
	}
	values := map[string]string{}
	for _, item := range instance.Metadata.Items {
		if item.Value != nil {
			values[item.Key] = *item.Value
		}
	}
	for key, value := range target.Metadata {
		if values[key] != value {
			return nil, failure{70, "instance release metadata differs from the group"}
		}
	}
	expectedStartup := startupScript(target.Properties.Metadata)
	if memberTemplate != target.Template {
		expectedStartup = target.Startup
	}
	if values["startup-script"] != expectedStartup || expectedStartup == "" ||
		!reflect.DeepEqual(instance.ServiceAccounts, target.Properties.ServiceAccounts) ||
		!strings.HasSuffix(instance.MachineType, "/machineTypes/"+target.Properties.MachineType) ||
		len(target.Properties.NetworkInterfaces) != 1 || nic.Subnetwork != target.Properties.NetworkInterfaces[0].Subnetwork {
		return nil, failure{70, "instance startup, runtime identity, sizing or subnet changed"}
	}
	return &instance, nil
}

func (target maintenanceTarget) matchesTemplate(value, expected string) bool {
	id := target.TemplateID
	if expected != target.Template {
		id = target.ReplacementID
	}
	return value == expected || (id != "" && value == "https://www.googleapis.com/compute/v1/projects/"+target.Project+"/global/instanceTemplates/"+id)
}

func startupScript(metadata *compute.Metadata) string {
	if metadata != nil {
		for _, item := range metadata.Items {
			if item.Key == "startup-script" && item.Value != nil {
				return *item.Value
			}
		}
	}
	return ""
}

func withoutStartup(properties *compute.InstanceProperties) compute.InstanceProperties {
	result := *properties
	metadata := *properties.Metadata
	metadata.Fingerprint = ""
	metadata.Items = slices.DeleteFunc(slices.Clone(metadata.Items), func(item *compute.MetadataItems) bool { return item.Key == "startup-script" })
	slices.SortFunc(metadata.Items, func(left, right *compute.MetadataItems) int { return strings.Compare(left.Key, right.Key) })
	result.Metadata = &metadata
	return result
}

func maintenanceReplace(ctx context.Context, args []string, getenv func(string) string, execute func(context.Context, io.Writer, string, ...string) error) error {
	if len(args) != 3 {
		return failure{64, "maintenance-replace requires private targets, outputs and evidence files"}
	}
	if !maintenanceEnabled(getenv) {
		return failure{77, "protected maintenance activation and paused releases are required"}
	}
	var targets []maintenanceTarget
	var outputs struct {
		Templates struct {
			Value map[string]struct {
				URL string `json:"url"`
				ID  string `json:"id"`
			}
		} `json:"database_maintenance_templates"`
	}
	if privateJSON(args[0], &targets) != nil || privateJSON(args[1], &outputs) != nil || len(targets) < 1 || len(targets) > 2 {
		return failure{65, "maintenance inputs are unavailable"}
	}
	var evidence []object
	seen := map[string]bool{}
	for index, target := range targets {
		h := target.host(execute)
		selected := outputs.Templates.Value[strings.ReplaceAll(target.Service, "-", "_")]
		if (target.Service != "json-keys" && target.Service != "authentication") || seen[target.Service] ||
			!matches(`[a-z][a-z0-9-]{4,28}[a-z0-9]`, target.Project) || !matches(`[a-z]+-[a-z]+[0-9]+-[a-z]`, target.Zone) ||
			!matches(`[1-9][0-9]*`, target.DiskID) || !matches(`[1-9][0-9]*`, target.TemplateID) || !validTemplate(target.Template, target.Project) ||
			!h.validRelease(target.Metadata) || !validStatus(target.Boot) || !matches(`[1-9][0-9]*`, target.InstanceID) ||
			target.Instance == "" || target.Address == "" || target.Properties == nil || target.Startup == "" ||
			selected.URL == target.Template || !matches(`[1-9][0-9]*`, selected.ID) {
			return failure{65, "maintenance target is invalid or duplicated"}
		}
		seen[target.Service] = true
		target.ReplacementID = selected.ID
		targets[index] = target
		template, err := h.template(ctx, selected.URL)
		if err != nil || strconv.FormatUint(template.Id, 10) != selected.ID {
			return failure{70, "converged template incarnation is unconfirmed"}
		}
		old, current := target.Properties, template.Properties
		if old.Metadata == nil || current.Metadata == nil {
			return failure{70, "template metadata is missing"}
		}
		if startupScript(current.Metadata) != target.Startup || !reflect.DeepEqual(withoutStartup(old), withoutStartup(current)) {
			return failure{70, "converged template differs beyond the reviewed startup script"}
		}
		instance, err := target.observe(ctx, execute, selected.URL, target.Template)
		if err != nil || strconv.FormatUint(instance.Id, 10) != target.InstanceID {
			return failure{70, "the selected host changed before its recovery checks"}
		}
		if err := h.snapshot(ctx); err != nil {
			return err
		}
		record := object{"service": target.Service, "diskId": target.DiskID, "privateAddress": target.Address, "oldInstanceId": target.InstanceID, "template": selected.URL, "templateId": selected.ID}
		for _, kind := range []string{"backup", "restore"} {
			job := "agora-postgres-" + kind + "-" + target.Service
			name, err := h.command(ctx, "run", "jobs", "execute", job, "--project="+h.project, "--region="+h.region(), "--wait", "--quiet", "--format=value(metadata.name)")
			if err != nil || !matches(job+`-[a-z0-9]+`, name) {
				return failure{70, "required backup or clean restore check failed; no host replaced"}
			}
			record[kind+"Execution"] = name
		}
		evidence = append(evidence, record)
	}
	for index, target := range targets {
		h := target.host(execute)
		selected := outputs.Templates.Value[strings.ReplaceAll(target.Service, "-", "_")]
		instance, err := target.observe(ctx, execute, selected.URL, target.Template)
		boot, bootErr := h.current(ctx)
		if err != nil || bootErr != nil || boot != target.Boot || strconv.FormatUint(instance.Id, 10) != target.InstanceID {
			return failure{70, "host changed after backup checks; replacement blocked"}
		}
		if err := h.snapshot(ctx); err != nil {
			return err
		}
		for _, step := range [][]string{
			{"update-instances", h.group(), "--instances=" + target.Instance, "--minimal-action=replace", "--most-disruptive-allowed-action=replace", "--quiet"},
			{"wait-until", h.group(), "--stable", "--timeout=600", "--quiet"},
		} {
			if _, err := h.compute(ctx, append([]string{"instance-groups", "managed"}, step...)...); err != nil {
				return failure{70, "replacement outcome is uncertain; keep the maintenance hold and releases paused"}
			}
		}
		if err := h.wait(ctx, target.Metadata[revisionKey], target.Boot); err != nil {
			return err
		}
		instance, err = target.observe(ctx, execute, selected.URL, selected.URL)
		if err != nil || strconv.FormatUint(instance.Id, 10) == target.InstanceID {
			return failure{70, "replacement identity or preserved state is unconfirmed"}
		}
		evidence[index]["newInstanceId"] = strconv.FormatUint(instance.Id, 10)
		evidence[index]["completedAt"] = time.Now().UTC().Format(time.RFC3339)
	}
	data, err := json.Marshal(evidence)
	if err != nil {
		return err
	}
	return os.WriteFile(args[2], data, 0o600)
}
