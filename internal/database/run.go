package database

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
	"regexp"
	"strings"

	"github.com/a-novel/infra/internal/custody"
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
	counts := map[string][2]int{"current": {4, 4}, "wait": {6, 6}, "prepare": {6, 8}, "deploy": {9, 9}, "restore": {6, 6}, "recover-first-launch": {7, 7}}
	if len(args) < 4 || counts[args[0]][0] == 0 || len(args) < counts[args[0]][0] || len(args) > counts[args[0]][1] {
		return "", failure{64, "usage: infra database-release <current|wait|prepare|deploy|restore|recover-first-launch> <project> <zone> <service> ..."}
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
	h.disk, args = args[0], args[1:]
	if !matches(`[1-9][0-9]*`, h.disk) {
		return "", failure{65, "invalid data disk ID"}
	}
	if action != "restore" && !matches(`[a-f0-9]{40}`, args[0]) {
		return "", failure{65, "invalid database revision"}
	}
	var err error
	switch action {
	case "prepare":
		proof, expected := "", ""
		if len(args) > 1 {
			proof = args[1]
		}
		if len(args) > 2 {
			expected = args[2]
		}
		if expected != "" && !matches(`[a-f0-9]{64}`, expected) {
			return "", failure{65, "invalid metadata hash"}
		}
		err = h.prepare(ctx, args[0], proof, expected)
	case "deploy":
		metadata := h.metadata(args[0], args[1], args[2], args[3])
		if !h.validRelease(metadata) {
			return "", failure{65, "invalid database image or password versions"}
		}
		if proof := getenv("DATABASE_CHANGE_PROOF"); proof != "" {
			err = h.checkProof(ctx, proof, args[0])
		} else {
			err = h.prepare(ctx, args[0], "", "")
		}
		if err == nil {
			err = h.restart(ctx, metadata)
		}
	case "restore":
		var metadata map[string]string
		metadata, err = h.receiptMetadata(args[0])
		if err == nil {
			err = h.restart(ctx, metadata)
		}
	case "recover-first-launch":
		err = h.recover(ctx, args[0], args[1], getenv)
	}
	return "Database " + action + " completed.", err
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

func (h host) metadata(revision, image, password, backup string) map[string]string {
	return map[string]string{revisionKey: revision, "agora-" + h.service + "-database-image": image, "agora-" + h.service + "-postgres-password-version": password, "agora-" + h.service + "-postgres-backup-password-version": backup}
}

func (h host) validRelease(metadata map[string]string) bool {
	prefix := h.region() + "-docker.pkg.dev/" + h.project + "/agora-production/service-" + h.service + "/database@sha256:"
	image := metadata["agora-"+h.service+"-database-image"]
	return len(metadata) == 4 && matches(`[a-f0-9]{40}`, metadata[revisionKey]) && strings.HasPrefix(image, prefix) && matches(`[a-f0-9]{64}`, strings.TrimPrefix(image, prefix)) &&
		matches(`[1-9][0-9]*`, metadata["agora-"+h.service+"-postgres-password-version"]) && matches(`[1-9][0-9]*`, metadata["agora-"+h.service+"-postgres-backup-password-version"])
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
	if len(values) != 4 {
		return nil, failure{70, "database metadata differs from the four-key contract"}
	}
	metadata := make(map[string]string, 4)
	for key := range h.metadata("", "", "0", "0") {
		if values[key] == nil {
			return nil, failure{70, "database metadata differs from the four-key contract"}
		}
		metadata[key] = *values[key]
	}
	if metadata[revisionKey] != "" && !matches(`[a-f0-9]{40}`, metadata[revisionKey]) {
		return nil, failure{70, "invalid live database revision"}
	}
	return metadata, nil
}

func (h host) receiptMetadata(file string) (map[string]string, error) {
	data, err := read(file)
	if err != nil {
		return nil, err
	}
	if data == nil {
		return h.metadata("", "", "0", "0"), nil
	}
	key, prefix := strings.ReplaceAll(h.service, "-", "_"), strings.ReplaceAll(h.service, "json-keys", "jsonKeys")
	password, backup := get(data, prefix+"PasswordVersion"), get(data, prefix+"BackupPasswordVersion")
	_, passwordNumber := password.(json.Number)
	_, backupNumber := backup.(json.Number)
	metadata := h.metadata(text(data, "hosts", key, "releaseRevision"), text(data, prefix+"Image"), text(data, prefix+"PasswordVersion"), text(data, prefix+"BackupPasswordVersion"))
	if get(data, "hosts", key, "dataDiskId") != h.disk || !passwordNumber || !backupNumber || !h.validRelease(metadata) {
		return nil, failure{65, "receipt does not identify the selected disk and image family"}
	}
	return metadata, nil
}

func (h host) recover(ctx context.Context, revision, bucket string, getenv func(string) string) error {
	if !matches(`[a-z0-9][a-z0-9._-]{1,220}[a-z0-9]`, bucket) {
		return failure{65, "invalid receipt bucket"}
	}
	dir, err := os.MkdirTemp("", "infra-first-launch-")
	if err != nil {
		return err
	}
	defer func() { _ = os.RemoveAll(dir) }() // Best-effort cleanup of this invocation's private files.
	file := filepath.Join(dir, "receipt.json")
	switch custody.Run(ctx, []string{"receipt", "latest", bucket, file}, getenv, h.execute, io.Discard, io.Discard) {
	case 0:
		receipt, err := read(file)
		if err != nil || text(receipt, "activeTfvars", "workload_project_id") != h.project || get(receipt, "database") == nil || get(receipt, "database", "hosts") != nil {
			return failure{70, "a successful release receipt exists; use normal receipt rollback"}
		}
	case 4:
	default:
		return failure{70, "cannot establish first-launch receipt absence"}
	}
	metadata, err := h.liveMetadata(ctx)
	if err != nil {
		return err
	}
	if err = h.checkDisk(ctx); err != nil {
		return err
	}
	idle := h.metadata("", "", "0", "0")
	if maps.Equal(metadata, idle) {
		return nil
	}
	if metadata[revisionKey] != revision || !h.validRelease(metadata) {
		return failure{70, "live database metadata is not the exact interrupted first-launch state"}
	}
	return h.restart(ctx, idle)
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
