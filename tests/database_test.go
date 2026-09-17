package tests_test

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"maps"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"testing/synctest"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/a-novel/infra/internal/database"
)

func TestDatabase(t *testing.T) {
	t.Parallel()
	for _, service := range []string{"authentication", "json-keys"} {
		for _, action := range []string{"prepare", "deploy", "cached", "restore", "idle", "recover-first-launch"} {
			t.Run(service+"/"+action, func(t *testing.T) {
				t.Parallel()
				c := newDatabaseCloud(t, service)
				original := maps.Clone(c.metadata)
				command, args := action, c.deploy()
				switch action {
				case "prepare", "cached":
					proof := filepath.Join(c.dir, "proof.json")
					expectCode(t, 0, c.run(t, "prepare", c.identity.Commit, proof, databaseHash(t, c.metadata)), c.output.String())
					info, err := os.Stat(proof)
					require.NoError(t, err)
					require.Equal(t, os.FileMode(0o600), info.Mode().Perm())
					require.Equal(t, databaseHash(t, original), readJSON(t, proof)["currentMetadataSha256"])
					require.Equal(t, []string{"disk", "metadata", "snapshot", "backup"}, c.calls)
					if action == "prepare" {
						return
					}
					c.env["DATABASE_CHANGE_PROOF"], c.calls, command = proof, nil, "deploy"
				case "restore", "idle":
					file := filepath.Join(c.dir, "database.json")
					var value any = nested(c.receipt, "database")
					if action == "idle" {
						value = nil
					}
					writeJSON(t, file, value)
					command, args = "restore", []string{file}
				case "recover-first-launch":
					args = []string{c.metadata[isolationRevision], "fixture-receipts"}
				}
				expectCode(t, 0, c.run(t, command, args...), c.output.String())
				require.Equal(t, 1, c.writes)
				require.Contains(t, c.calls, "restart")
				require.Contains(t, c.calls, "stable")
				if action == "deploy" {
					require.Equal(t, []string{"disk", "metadata", "snapshot", "backup", "disk", "instance", "status", "write", "restart", "stable", "instance", "status"}, c.calls)
				} else {
					require.NotContains(t, c.calls, "backup")
				}
				switch action {
				case "deploy", "cached":
					original[isolationRevision] = c.identity.Commit
				case "idle", "recover-first-launch":
					for key := range original {
						original[key] = "0"
					}
					original[isolationRevision], original["agora-"+service+"-database-image"] = "", ""
				}
				require.Equal(t, original, c.metadata)
			})
		}
	}
}

func TestDatabaseRefusals(t *testing.T) {
	t.Parallel()
	for _, scenario := range []string{"InvalidRevision", "PeerImage", "Disk", "MetadataShape", "NullRevision", "MetadataDenied", "ExpectedHash", "StaleSnapshot", "FutureSnapshot", "ManualSnapshot", "PeerSnapshot", "SnapshotDenied", "Backup", "ReadinessDenied", "MalformedStatus", "PartialWrite", "Restart", "Stable", "Cancelled", "ReceiptDisk", "ReceiptVersion"} {
		t.Run(scenario, func(t *testing.T) {
			t.Parallel()
			c := newDatabaseCloud(t, "authentication")
			command, args, code, writes := "deploy", c.deploy(), 70, 0
			switch scenario {
			case "InvalidRevision":
				args[0], code = "bad", 65
			case "PeerImage":
				args[1], code = strings.ReplaceAll(args[1], "authentication", "json-keys"), 65
			case "Disk":
				c.disk = "999"
			case "MetadataShape":
				c.metadata["unexpected"] = privateValue
			case "NullRevision":
				c.nullRevision = true
			case "MetadataDenied":
				c.fail = "metadata"
			case "ExpectedHash":
				command, args = "prepare", []string{c.identity.Commit, "", strings.Repeat("0", 64)}
			case "StaleSnapshot":
				c.snapshot["creationTimestamp"] = time.Now().Add(-27 * time.Hour).Format(time.RFC3339)
			case "FutureSnapshot":
				c.snapshot["creationTimestamp"] = time.Now().Add(time.Hour).Format(time.RFC3339)
			case "ManualSnapshot":
				c.snapshot["autoCreated"] = false
			case "PeerSnapshot":
				nested(c.snapshot, "labels")["component"] = "json-keys"
			case "SnapshotDenied":
				c.fail = "snapshot"
			case "Backup":
				c.fail = "backup"
			case "ReadinessDenied":
				c.fail = "status"
			case "MalformedStatus":
				c.statuses = []string{privateValue}
			case "PartialWrite":
				c.fail, writes = "write", 1
			case "Restart":
				c.fail, writes = "restart", 1
			case "Stable":
				c.fail, writes = "stable", 1
			case "Cancelled":
				c.cancelAt, writes = "write", 1
			case "ReceiptDisk", "ReceiptVersion":
				value := nested(c.receipt, "database")
				if scenario == "ReceiptDisk" {
					nested(value, "hosts", "authentication")["dataDiskId"] = "999"
				} else {
					value["authenticationPasswordVersion"] = "1"
				}
				file := filepath.Join(c.dir, "database.json")
				writeJSON(t, file, value)
				command, args, code = "restore", []string{file}, 65
			}
			expectCode(t, code, c.run(t, command, args...), c.output.String())
			require.Equal(t, writes, c.writes)
			if code == 65 {
				require.Empty(t, c.calls)
			}
			if scenario == "ExpectedHash" || scenario == "NullRevision" {
				require.Equal(t, []string{"disk", "metadata"}, c.calls)
			}
			if c.fail != "" {
				require.Equal(t, c.fail, c.calls[len(c.calls)-1], "stop at the first failed boundary")
			}
			if scenario == "Cancelled" {
				require.Equal(t, "write", c.calls[len(c.calls)-1])
			}
		})
	}
}

func TestDatabaseProof(t *testing.T) {
	t.Parallel()
	for _, scenario := range []string{"Empty", "Stale", "Future", "Peer", "Extra", "Drift"} {
		t.Run(scenario, func(t *testing.T) {
			t.Parallel()
			c := newDatabaseCloud(t, "json-keys")
			c.metadata[isolationRevision] = ""
			proof := filepath.Join(c.dir, "proof.json")
			expectCode(t, 0, c.run(t, "prepare", c.identity.Commit, proof), c.output.String())
			require.NotContains(t, c.calls, "backup")
			value := readJSON(t, proof)
			switch scenario {
			case "Stale":
				value["checkedAt"] = time.Now().Unix() - 601
			case "Future":
				value["checkedAt"] = time.Now().Unix() + 60
			case "Peer":
				value["service"] = "authentication"
			case "Extra":
				value["unexpected"] = privateValue
			case "Drift":
				c.metadata[isolationRevision] = strings.Repeat("c", 40)
			}
			writeJSON(t, proof, value)
			c.env["DATABASE_CHANGE_PROOF"], c.calls = proof, nil
			code := c.run(t, "deploy", c.deploy()...)
			if scenario == "Empty" {
				expectCode(t, 0, code, c.output.String())
			} else {
				expectCode(t, 70, code, c.output.String())
				require.Zero(t, c.writes)
				require.NotContains(t, c.calls, "disk")
			}
		})
	}
}

func TestDatabaseReadiness(t *testing.T) {
	t.Parallel()
	for _, scenario := range []string{"NewBoot", "OldBoot", "Absent", "Failed", "Cancelled", "MultipleHosts"} {
		t.Run(scenario, func(t *testing.T) {
			t.Parallel()
			synctest.Test(t, func(t *testing.T) {
				c := newDatabaseCloud(t, "json-keys")
				previous := "healthy:" + c.metadata[isolationRevision] + ":11111111-1111-1111-1111-111111111111"
				c.statuses = []string{previous, strings.ReplaceAll(previous, "11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222")}
				switch scenario {
				case "OldBoot":
					c.statuses = []string{previous}
				case "Absent":
					c.statuses = []string{"absent"}
				case "Failed":
					c.statuses = []string{strings.Replace(c.statuses[1], "healthy:", "failed:", 1)}
				case "Cancelled":
					c.statuses, c.cancelAt = []string{previous}, "status"
				case "MultipleHosts":
					c.multiple = true
				}
				if scenario == "Absent" {
					expectCode(t, 0, c.run(t, "current"), c.output.String())
					require.Equal(t, "absent\n", c.output.String())
					return
				}
				started := time.Now()
				code := c.run(t, "wait", c.metadata[isolationRevision], previous)
				require.Equal(t, scenario == "NewBoot", code == 0, c.output.String())
				if scenario == "OldBoot" {
					require.Equal(t, 595*time.Second, time.Since(started))
					require.Len(t, c.calls, 87)
				}
				if scenario == "NewBoot" {
					require.Equal(t, 7*time.Second, time.Since(started))
				}
			})
		})
	}
}

func TestFirstLaunchRecovery(t *testing.T) {
	t.Parallel()
	for _, scenario := range []string{"Idle", "WrongRevision", "UnexpectedImage", "Receipt", "Legacy", "OtherProject", "Denied"} {
		t.Run(scenario, func(t *testing.T) {
			t.Parallel()
			c := newDatabaseCloud(t, "authentication")
			revision := c.metadata[isolationRevision]
			switch scenario {
			case "Idle":
				for key := range c.metadata {
					c.metadata[key] = "0"
				}
				c.metadata[isolationRevision], c.metadata["agora-authentication-database-image"] = "", ""
			case "WrongRevision":
				revision = strings.Repeat("f", 40)
			case "UnexpectedImage":
				c.metadata["agora-authentication-database-image"] = privateValue
			case "Receipt", "Legacy", "OtherProject":
				c.hasReceipt = true
				if scenario != "Receipt" {
					delete(nested(c.receipt, "database"), "hosts")
					delete(nested(c.receipt, "activeTfvars"), "database_hosts")
					nested(c.receipt, "activeTfvars")["database_private_ip"] = "10.20.0.99"
				}
				if scenario == "OtherProject" {
					nested(c.receipt, "activeTfvars")["workload_project_id"] = "other-project"
				}
			case "Denied":
				c.fail = "inventory"
			}
			code := c.run(t, "recover-first-launch", revision, "fixture-receipts")
			require.Equal(t, scenario == "Idle" || scenario == "Legacy", code == 0, c.output.String())
			if scenario == "Legacy" {
				require.Equal(t, 1, c.writes)
			} else {
				require.Zero(t, c.writes)
			}
		})
	}
}

type databaseCloud struct {
	t *testing.T
	*releaseFixture
	service, project, zone, disk, fail, cancelAt string
	metadata                                     map[string]string
	snapshot                                     object
	calls, statuses                              []string
	writes                                       int
	hasReceipt, multiple, nullRevision           bool
	cancel                                       context.CancelFunc
	output                                       bytes.Buffer
}

func newDatabaseCloud(t *testing.T, service string) *databaseCloud {
	t.Helper()
	f := compiledFixture(t)
	key, prefix := strings.ReplaceAll(service, "-", "_"), strings.ReplaceAll(service, "json-keys", "jsonKeys")
	data, host := nested(f.receipt, "database"), nested(f.receipt, "database", "hosts", key)
	c := &databaseCloud{t: t, releaseFixture: f, service: service, project: f.config["workload_project_id"].(string), zone: f.config["database_zone"].(string), disk: host["dataDiskId"].(string)}
	c.metadata = map[string]string{isolationRevision: host["releaseRevision"].(string), "agora-" + service + "-database-image": data[prefix+"Image"].(string), "agora-" + service + "-postgres-password-version": fmt.Sprint(data[prefix+"PasswordVersion"]), "agora-" + service + "-postgres-backup-password-version": fmt.Sprint(data[prefix+"BackupPasswordVersion"])}
	c.snapshot = object{"autoCreated": true, "status": "READY", "sourceDiskId": c.disk, "sourceDisk": "https://www.googleapis.com/compute/v1/projects/" + c.project + "/zones/" + c.zone + "/disks/agora-data-" + service, "creationTimestamp": time.Now().Add(-25 * time.Hour).Format(time.RFC3339), "storageLocations": []string{"europe-west1"}, "labels": object{"component": service, "application": "agora", "environment": "production", "managed-by": "opentofu", "plane": "workload", "role": "database-snapshot"}}
	return c
}

func (c *databaseCloud) deploy() []string {
	return []string{c.identity.Commit, c.metadata["agora-"+c.service+"-database-image"], c.metadata["agora-"+c.service+"-postgres-password-version"], c.metadata["agora-"+c.service+"-postgres-backup-password-version"]}
}

func (c *databaseCloud) run(t *testing.T, action string, args ...string) int {
	t.Helper()
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	c.cancel = cancel
	base := []string{action, c.project, c.zone, c.service}
	if action != "current" && action != "wait" {
		base = append(base, nested(c.config, "database_hosts", strings.ReplaceAll(c.service, "-", "_"))["data_disk_id"].(string))
	}
	code := database.Run(ctx, append(base, args...), func(key string) string { return c.env[key] }, c.execute, &c.output, &c.output)
	require.NotContains(t, c.output.String(), privateValue)
	require.NotContains(t, c.output.String(), "sha256:")
	return code
}

func databaseHash(t *testing.T, metadata map[string]string) string {
	t.Helper()
	return fmt.Sprintf("%x", sha256.Sum256([]byte(jsonText(t, metadata))))
}

func (c *databaseCloud) execute(ctx context.Context, out io.Writer, name string, args ...string) error {
	t := c.t
	t.Helper()
	require.NoError(t, ctx.Err())
	require.Equal(t, "gcloud", name)
	require.GreaterOrEqual(t, len(args), 3)
	var value any
	key, operation := strings.Join(args[:3], " "), ""
	if args[0] != "storage" {
		require.Contains(t, args, "--project="+c.project)
		if args[1] != "snapshots" {
			if args[0] == "compute" {
				require.Contains(t, args, "--zone="+c.zone)
			} else {
				require.Contains(t, args, "--region=europe-west1")
			}
		}
	}
	switch key {
	case "storage objects list":
		operation = "inventory"
		if c.hasReceipt {
			value = "production/success/00000000000000000123-00001.json"
		} else {
			value = ""
		}
	case "storage cp gs://fixture-receipts/production/success/00000000000000000123-00001.json":
		writeJSON(t, args[3], c.receipt)
		return nil
	case "compute disks describe":
		require.Equal(t, "agora-data-"+c.service, args[3])
		operation, value = "disk", c.disk
	case "compute instance-groups managed":
		operation = args[3]
		target := args[4]
		if operation == "all-instances-config" {
			target = args[5]
		}
		require.Equal(t, "agora-database-"+c.service, target)
		switch operation {
		case "describe":
			operation, value = "metadata", object{"allInstancesConfig": object{"properties": object{"metadata": c.metadata}}}
			if c.nullRevision {
				metadata := object{}
				for key, value := range c.metadata {
					metadata[key] = value
				}
				metadata[isolationRevision] = nil
				value = object{"allInstancesConfig": object{"properties": object{"metadata": metadata}}}
			}
		case "list-instances":
			operation, value = "instance", "agora-database-"+c.service+"-test"
			if c.multiple {
				value = value.(string) + "\n" + value.(string)
			}
		case "all-instances-config":
			operation = "write"
			require.Equal(t, "update", args[4])
			var metadata string
			for _, arg := range args {
				if strings.HasPrefix(arg, "--metadata=") {
					metadata = strings.TrimPrefix(arg, "--metadata=")
				}
			}
			require.NotEmpty(t, metadata)
			c.metadata = map[string]string{}
			for entry := range strings.SplitSeq(metadata, ",") {
				key, value, ok := strings.Cut(entry, "=")
				require.True(t, ok)
				c.metadata[key] = value
			}
			require.Len(t, c.metadata, 4)
			c.writes++
		case "update-instances":
			operation = "restart"
			require.Equal(t, []string{"--all-instances", "--minimal-action=restart", "--most-disruptive-allowed-action=restart", "--quiet", "--project=" + c.project, "--zone=" + c.zone}, args[5:])
		case "wait-until":
			operation = "stable"
			require.Equal(t, []string{"--stable", "--timeout=600", "--quiet", "--project=" + c.project, "--zone=" + c.zone}, args[5:])
		default:
			t.Fatalf("unexpected group operation: %v", args)
		}
	case "compute instances get-guest-attributes":
		require.Equal(t, []string{"agora-database-" + c.service + "-test", "--query-path=agora/database-release", "--format=value(value)", "--project=" + c.project, "--zone=" + c.zone}, args[3:])
		operation, value = "status", "healthy:"+c.metadata[isolationRevision]+":11111111-1111-1111-1111-111111111111"
		if c.writes > 0 {
			value = strings.ReplaceAll(value.(string), "11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222")
		}
		if c.metadata[isolationRevision] == "" {
			value = strings.Replace(value.(string), "healthy::", "idle:none:", 1)
		}
		if len(c.statuses) > 0 {
			value = c.statuses[0]
			if len(c.statuses) > 1 {
				c.statuses = c.statuses[1:]
			}
		}
	case "compute snapshots list":
		operation, value = "snapshot", []any{c.snapshot}
		require.Contains(t, args, "--filter=labels.application=agora AND labels.environment=production AND labels.role=database-snapshot AND labels.component="+c.service)
		require.Contains(t, args, "--limit=1")
		require.Contains(t, args, "--sort-by=~creationTimestamp")
	case "run jobs execute":
		operation = "backup"
		require.Equal(t, []string{"agora-postgres-backup-" + c.service, "--project=" + c.project, "--region=europe-west1", "--wait", "--quiet", "--format=none"}, args[3:])
	default:
		t.Fatalf("unexpected command: %s %v", name, args)
	}
	c.calls = append(c.calls, operation)
	if c.cancelAt == operation {
		c.cancel()
	}
	if c.fail == operation {
		return errors.New(privateValue)
	}
	if operation == "status" && value == "absent" {
		return &exec.ExitError{Stderr: []byte("Guest Attribute was not found (404)")}
	}
	if value, ok := value.(string); ok {
		_, err := fmt.Fprintln(out, value)
		return err
	}
	if value != nil {
		return json.NewEncoder(out).Encode(value)
	}
	return nil
}

func TestDatabaseDriverProof(t *testing.T) {
	t.Parallel()
	for _, service := range []string{"authentication", "json_keys"} {
		t.Run(service, func(t *testing.T) {
			t.Parallel()
			c := newDatabaseCloud(t, strings.ReplaceAll(service, "_", "-"))
			c.change(service, true)
			compiled := c.compile(t)
			nested(compiled, "previousDatabase", "hosts", service)["releaseRevision"] = strings.Repeat("f", 40)
			writeJSON(t, filepath.Join(c.files[3], "release.json"), compiled)
			for _, name := range []string{"sha256sum", "cut"} {
				path, err := exec.LookPath(name)
				require.NoError(t, err)
				c.link(t, name, path)
			}
			c.driver(t, "preflight", []invocation{
				{Name: "preflight-release.sh", Args: []string{filepath.Join(c.files[3], "release.json")}},
				{Name: "infra", Args: []string{"database-release", "prepare", c.project, c.zone, c.service, c.disk, c.identity.Commit, filepath.Join(c.files[3], "database-change-"+service+".json"), databaseHash(t, c.metadata)}},
			})
		})
	}
}
