package isolation

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"os"
	"reflect"
	"strings"

	"github.com/santhosh-tekuri/jsonschema/v6"
)

type object = map[string]any

const revisionKey = "agora-database-release-revision"

// snapshot excludes volatile provider bookkeeping, retaining restart and identity evidence.
type snapshot struct {
	Metadata                           object
	Template, Versions                 any
	Instance, ID, Started, Disk, Guest string
	Interfaces, Disks                  []object
}

func (d *drill) metadata(service string) object {
	key, prefix := strings.ReplaceAll(service, "-", "_"), strings.ReplaceAll(service, "json-keys", "jsonKeys")
	return object{
		revisionKey:                                              text(d.database, "hosts", key, "releaseRevision"),
		"agora-" + service + "-database-image":                   text(d.database, prefix+"Image"),
		"agora-" + service + "-postgres-password-version":        text(d.database, prefix+"PasswordVersion"),
		"agora-" + service + "-postgres-backup-password-version": text(d.database, prefix+"BackupPasswordVersion"),
	}
}

func sameConfiguration(actual, expected object) bool {
	if !matches(`[a-f0-9]{40}`, text(actual, revisionKey)) {
		return false
	}
	a, b := maps.Clone(actual), maps.Clone(expected)
	delete(a, revisionKey)
	delete(b, revisionKey)
	return reflect.DeepEqual(a, b)
}

func (s snapshot) healthy(expected object) bool {
	return reflect.DeepEqual(s.Metadata, expected) && strings.HasPrefix(s.Guest, "healthy:"+text(expected, revisionKey)+":")
}

func (d *drill) cloud(ctx context.Context, args ...string) ([]byte, error) {
	return d.command(ctx, "gcloud", append(args, "--project="+d.project, "--zone="+d.zone)...)
}

func (d *drill) group(ctx context.Context, service string) (object, error) {
	data, err := d.cloud(ctx, "compute", "instance-groups", "managed", "describe", "agora-database-"+service, "--format=json")
	if err != nil {
		return nil, err
	}
	return decode(data)
}

func (d *drill) inspect(ctx context.Context, service string) (s snapshot, err error) {
	// Command errors contain only the failed boundary, never provider payloads.
	defer func() {
		if err != nil {
			err = fmt.Errorf("%s host inspection: %w", service, err)
		}
	}()
	group, err := d.group(ctx, service)
	if err != nil {
		return s, err
	}
	if get(group, "targetSize") != json.Number("1") || get(group, "status", "isStable") != true || get(group, "status", "versionTarget", "isReached") != true ||
		get(group, "status", "allInstancesConfig", "effective") != true || get(group, "updatePolicy", "type") != "OPPORTUNISTIC" ||
		get(group, "statefulPolicy", "preservedState", "disks", "agora-data", "autoDelete") != "NEVER" || get(group, "statefulPolicy", "preservedState", "internalIPs", "nic0", "autoDelete") != "NEVER" {
		return s, errors.New("group is not stable and preserved")
	}
	instance, err := d.cloud(ctx, "compute", "instance-groups", "managed", "list-instances", "agora-database-"+service, "--format=value(instance.basename())")
	if err != nil {
		return s, err
	}
	s.Instance = strings.TrimSpace(string(instance))
	if !matches("agora-database-"+service+`-[a-z0-9]+`, s.Instance) {
		return s, errors.New("expected one generated instance")
	}
	data, err := d.cloud(ctx, "compute", "instances", "describe", s.Instance, "--format=json")
	if err != nil {
		return s, err
	}
	vm, err := decode(data)
	if err != nil {
		return s, err
	}
	disk, err := d.cloud(ctx, "compute", "disks", "describe", "agora-data-"+service, "--format=value(id)")
	if err != nil {
		return s, err
	}
	s.Disk, s.ID, s.Started = strings.TrimSpace(string(disk)), text(vm, "id"), text(vm, "lastStartTimestamp")
	host := get(d.database, "hosts", strings.ReplaceAll(service, "-", "_"))
	interfaces, _ := vm["networkInterfaces"].([]any)
	if s.Disk != text(host, "dataDiskId") || vm["name"] != s.Instance || vm["status"] != "RUNNING" || !matches(`[1-9][0-9]*`, s.ID) || s.Started == "" || len(interfaces) != 1 ||
		get(interfaces[0], "networkIP") != get(host, "privateIp") {
		return s, errors.New("instance differs from receipt")
	}
	access := get(interfaces[0], "accessConfigs")
	if access != nil && !reflect.DeepEqual(access, []any{}) {
		return s, errors.New("instance has external access")
	}
	for _, network := range interfaces {
		s.Interfaces = append(s.Interfaces, selectFields(network, "network", "subnetwork", "networkIP"))
	}
	disks, _ := vm["disks"].([]any)
	matched := 0
	for _, disk := range disks {
		if get(disk, "deviceName") == "agora-data" && get(disk, "boot") == false && get(disk, "autoDelete") == false &&
			strings.HasSuffix(text(disk, "source"), "/projects/"+d.project+"/zones/"+d.zone+"/disks/agora-data-"+service) {
			matched++
		}
		s.Disks = append(s.Disks, selectFields(disk, "source", "deviceName", "boot", "autoDelete"))
	}
	if matched != 1 {
		return s, errors.New("expected one preserved data disk")
	}
	guest, err := d.command(ctx, "./ops/database-host-readiness.sh", "current", d.project, d.zone, service)
	if err != nil {
		return s, err
	}
	s.Guest = strings.TrimSpace(string(guest))
	s.Metadata, _ = get(group, "allInstancesConfig", "properties", "metadata").(object)
	s.Template, s.Versions = group["instanceTemplate"], group["versions"]
	return s, nil
}

func (d *drill) checkPeer(ctx context.Context, before snapshot) error {
	after, err := d.inspect(ctx, "json-keys")
	if err != nil || !reflect.DeepEqual(before, after) {
		return errors.New("JSON Keys changed during the isolation operation")
	}
	return nil
}

func get(value any, keys ...string) any {
	for _, key := range keys {
		object, _ := value.(object)
		value = object[key]
	}
	return value
}

func text(value any, keys ...string) string {
	switch value := get(value, keys...).(type) {
	case string:
		return value
	case json.Number:
		return string(value)
	default:
		return ""
	}
}

func selectFields(value any, keys ...string) object {
	selected := object{}
	for _, key := range keys {
		selected[key] = get(value, key)
	}
	return selected
}

func decode(data []byte) (object, error) {
	value, err := jsonschema.UnmarshalJSON(bytes.NewReader(data))
	document, ok := value.(object)
	if err != nil || !ok || document == nil {
		return nil, errors.New("invalid private drill document")
	}
	return document, nil
}

func write(file string, value any) error {
	data, err := json.Marshal(value)
	if err != nil {
		return errors.New("cannot encode private drill inputs")
	}
	if err = os.WriteFile(file, data, 0o600); err != nil {
		return errors.New("cannot stage private drill inputs")
	}
	return nil
}
