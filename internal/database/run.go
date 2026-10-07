package database

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"
	"strings"
)

type object = map[string]any

const revisionKey = "agora-database-release-revision"

type host struct {
	project, zone, service, disk string
	execute                      func(context.Context, io.Writer, string, ...string) error
}

type failure struct {
	code    int
	message string
}

func (err failure) Error() string { return err.message }

// Run handles one host's lifecycle. Invalid input returns 64/65; unproven cloud
// state returns 70. Provider diagnostics and private inputs never reach output.
func Run(ctx context.Context, args []string, getenv func(string) string, execute func(context.Context, io.Writer, string, ...string) error, stdout, stderr io.Writer) int {
	result, err := run(ctx, args, getenv, execute)
	if err == nil {
		_, err = fmt.Fprintln(stdout, result)
	}
	if err == nil {
		return 0
	}
	fault := failure{70, "database operation failed; inspect the protected operation"}
	_ = errors.As(err, &fault)
	_, _ = fmt.Fprintln(stderr, "STOP: "+fault.message) // Best effort on a closed diagnostic stream.
	return fault.code
}

func run(ctx context.Context, args []string, getenv func(string) string, execute func(context.Context, io.Writer, string, ...string) error) (string, error) {
	if len(args) > 0 {
		switch args[0] {
		case "maintenance-plan":
			return "Maintenance targets inspected; no host changed.", maintenancePlan(ctx, args[1:], getenv, execute)
		case "maintenance-replace":
			return "Maintenance completed with preserved disks and addresses.", maintenanceReplace(ctx, args[1:], getenv, execute, false)
		case "maintenance-recover":
			return "Maintenance reconciled with preserved disks and addresses.", maintenanceReplace(ctx, args[1:], getenv, execute, true)
		}
	}
	counts := map[string]int{"current": 4, "wait": 6}
	if len(args) < 4 || len(args) != counts[args[0]] {
		return "", failure{64, "usage: infra database-release <current|wait|maintenance-plan|maintenance-replace|maintenance-recover> <project> <zone> <service> ..."}
	}
	h := host{project: args[1], zone: args[2], service: args[3], execute: execute}
	if !matches(`[a-z][a-z0-9-]{4,28}[a-z0-9]`, h.project) || !matches(`[a-z]+-[a-z]+[0-9]+-[a-z]`, h.zone) || (h.service != "authentication" && h.service != "json-keys") {
		return "", failure{65, "invalid database coordinates"}
	}
	action, args := args[0], args[4:]
	if action == "current" {
		return h.current(ctx)
	}
	if action == "wait" {
		if !matches(`(?:[a-f0-9]{40}|none)`, args[0]) || (args[1] != "absent" && !validStatus(args[1])) {
			return "", failure{65, "invalid readiness expectation"}
		}
		return "Database host reported the expected new boot.", h.wait(ctx, args[0], args[1])
	}
	return "", failure{64, "invalid database operation"}
}

func (h host) region() string { return h.zone[:strings.LastIndex(h.zone, "-")] }
func (h host) group() string  { return "agora-database-" + h.service }

func (h host) command(ctx context.Context, args ...string) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", err
	}
	var output bytes.Buffer
	err := h.execute(ctx, &output, "gcloud", args...)
	return strings.TrimRight(output.String(), "\r\n"), err
}

func (h host) compute(ctx context.Context, args ...string) (string, error) {
	return h.command(ctx, append(append([]string{"compute"}, args...), "--project="+h.project, "--zone="+h.zone)...)
}

func (h host) checkDisk(ctx context.Context) error {
	id, err := h.compute(ctx, "disks", "describe", "agora-data-"+h.service, "--format=value(id)")
	if err != nil || id != h.disk {
		return failure{70, "live database disk differs from the selected disk"}
	}
	return nil
}

func (h host) validRelease(metadata map[string]string) bool {
	prefix := h.region() + "-docker.pkg.dev/" + h.project + "/agora-production/service-" + h.service + "/database@sha256:"
	image := metadata["agora-"+h.service+"-database-image"]
	backup, retained := metadata["agora-"+h.service+"-postgres-backup-password-version"]
	// Retained operation evidence can still identify the former four-field contract.
	fields := 3
	if retained {
		fields++
	}
	return len(metadata) == fields && (!retained || matches(`[1-9][0-9]*`, backup)) &&
		matches(`[a-f0-9]{40}`, metadata[revisionKey]) && strings.HasPrefix(image, prefix) && matches(`[a-f0-9]{64}`, strings.TrimPrefix(image, prefix)) &&
		matches(`[1-9][0-9]*`, metadata["agora-"+h.service+"-postgres-password-version"])
}

func (h host) liveMetadata(ctx context.Context) (map[string]string, error) {
	data, err := h.compute(ctx, "instance-groups", "managed", "describe", h.group(), "--format=json")
	if err != nil {
		return nil, failure{70, "database metadata could not be inspected"}
	}
	var group struct {
		AllInstancesConfig struct {
			Properties struct{ Metadata map[string]*string }
		}
	}
	if json.Unmarshal([]byte(data), &group) != nil {
		return nil, failure{70, "malformed database group"}
	}
	values := group.AllInstancesConfig.Properties.Metadata
	metadata := make(map[string]string, len(values))
	for key, value := range values {
		if value == nil {
			return nil, failure{70, "database release metadata is incomplete"}
		}
		metadata[key] = *value
	}
	if !h.validRelease(metadata) {
		return nil, failure{70, "invalid live database release"}
	}
	return metadata, nil
}

func read(file string) (object, error) {
	data, err := os.ReadFile(file)
	var value object
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	if err != nil || decoder.Decode(&value) != nil || decoder.Decode(&struct{}{}) != io.EOF {
		return nil, failure{65, "invalid private database document"}
	}
	return value, nil
}

func get(value any, keys ...string) any {
	for _, key := range keys {
		document, _ := value.(object)
		value = document[key]
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

func matches(pattern, value string) bool {
	return regexp.MustCompile("^(?:" + pattern + ")$").MatchString(value)
}
