package operator

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/netip"
	"strings"
)

type database struct {
	project string
	execute func(context.Context, io.Writer, string, ...string) error
}

type host struct{ service, group, zone, instance, ip string }

func (db database) run(ctx context.Context, output io.Writer, args ...string) error {
	if err := db.execute(ctx, output, "gcloud", append(args, "--project="+db.project)...); err != nil {
		return fmt.Errorf("database command failed: %w", err)
	}
	return nil
}

func (db database) read(ctx context.Context, args ...string) (string, error) {
	var output bytes.Buffer
	err := db.run(ctx, &output, args...)
	return strings.TrimRight(output.String(), "\n"), err
}

func (db database) host(ctx context.Context, service string) (host, error) {
	h := host{service: service, group: "agora-database-" + service}
	var err error
	h.zone, err = db.read(ctx, "compute", "instance-groups", "managed", "list", "--filter=name="+h.group, "--format=value(zone.basename())")
	if err != nil || !matches(`[a-z]+-[a-z]+[0-9]+-[a-z]`, h.zone) {
		return h, errors.New("expected exactly one database group zone")
	}
	h.instance, err = db.read(ctx, "compute", "instance-groups", "managed", "list-instances", h.group, "--zone="+h.zone, "--format=value(instance.basename())")
	if err != nil || !matches(h.group+`-[a-z0-9]+`, h.instance) {
		return h, errors.New("expected exactly one generated database instance")
	}
	h.ip, err = db.read(ctx, "compute", "instances", "describe", h.instance, "--zone="+h.zone, "--format=value(networkInterfaces[0].networkIP)")
	address, parseErr := netip.ParseAddr(h.ip)
	if err != nil || parseErr != nil || !address.Is4() || !address.IsPrivate() {
		return h, errors.New("database instance does not have one private IPv4 address")
	}
	return h, nil
}

func (db database) coordinates(ctx context.Context, output io.Writer) error {
	result := struct {
		Zone  string                       `json:"zone"`
		Hosts map[string]map[string]string `json:"hosts"`
	}{Hosts: map[string]map[string]string{}}
	for _, service := range []string{"authentication", "json-keys"} {
		h, err := db.host(ctx, service)
		if err != nil {
			return err
		}
		if result.Zone != "" && result.Zone != h.zone {
			return errors.New("database hosts must use the same configured zone")
		}
		disk, err := db.read(ctx, "compute", "disks", "describe", "agora-data-"+service, "--zone="+h.zone, "--format=value(id)")
		if err != nil || !matches(`[1-9][0-9]*`, disk) {
			return errors.New("invalid database disk ID")
		}
		result.Zone = h.zone
		result.Hosts[strings.ReplaceAll(service, "-", "_")] = map[string]string{"private_ip": h.ip, "data_disk_id": disk}
	}
	if err := json.NewEncoder(output).Encode(result); err != nil {
		return fmt.Errorf("write database coordinates: %w", err)
	}
	return nil
}

func (db database) inspect(ctx context.Context, h host, output io.Writer) error {
	if _, err := fmt.Fprintf(output, "Database group: %s\nDatabase instance: %s\nZone: %s\nPrivate IP: %s\n", h.group, h.instance, h.zone, h.ip); err != nil {
		return fmt.Errorf("write database inspection: %w", err)
	}
	commands := [][]string{
		{"compute", "instance-groups", "managed", "describe", h.group, "--zone=" + h.zone, "--format=yaml(name,targetSize,instanceGroup,updatePolicy,statefulPolicy,status)"},
		{"compute", "instances", "describe", h.instance, "--zone=" + h.zone, "--format=yaml(name,status,machineType,networkInterfaces,serviceAccounts,tags.items,shieldedInstanceConfig,disks.deviceName,disks.boot,disks.autoDelete,disks.mode,disks.source)"},
		{"compute", "disks", "describe", "agora-data-" + h.service, "--zone=" + h.zone, "--format=yaml(name,status,sizeGb,type,physicalBlockSizeBytes,users,labels)"},
		{"compute", "resource-policies", "describe", "agora-" + h.service + "-daily-snapshots", "--region=" + h.zone[:strings.LastIndex(h.zone, "-")], "--format=yaml(name,region,snapshotSchedulePolicy)"},
		{"compute", "snapshots", "list", "--filter=labels.application=agora AND labels.environment=production AND labels.role=database-snapshot AND labels.component=" + h.service, "--sort-by=~creationTimestamp", "--limit=1", "--format=table(name,autoCreated,status,creationTimestamp,sourceDisk.basename(),storageLocations,labels.role)"},
	}
	for _, rule := range []string{"agora-allow-" + h.service + "-postgres-ingress", "agora-allow-json-keys-postgres-egress", "agora-allow-authentication-postgres-egress", "agora-allow-iap-ssh", "agora-deny-other-vpc-egress"} {
		commands = append(commands, []string{"compute", "firewall-rules", "describe", rule, "--format=yaml(name,direction,priority,sourceRanges,destinationRanges,allowed,denied,targetTags)"})
	}
	for _, filter := range []string{`display_name:("Agora database")`, `display_name="Agora PostgreSQL recovery jobs unhealthy"`} {
		commands = append(commands, []string{"monitoring", "policies", "list", "--filter=" + filter, "--format=table(display_name,enabled,severity,conditions[0].display_name)"})
	}
	for _, args := range commands {
		if err := db.run(ctx, output, args...); err != nil {
			return err
		}
	}
	if _, err := fmt.Fprintln(output, "PASS database host inspection"); err != nil {
		return fmt.Errorf("write database inspection: %w", err)
	}
	return nil
}
