package tests_test

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/a-novel/infra/internal/isolation"
)

const isolationRevision = "agora-database-release-revision"

func TestIsolation(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name, operation string
		mutations       int
		success         bool
	}{
		{"Success", "drill", 2, true},
		{"Interrupted", "restore", 1, true},
		{"MovedManifest", "restore", 1, true},
		{"MovedManifest", "drill", 0, false},
		{"WrongReceipt", "drill", 0, false},
		{"SameRevision", "drill", 0, false},
		{"MetadataDrift", "drill", 0, false},
		{"MetadataDrift", "restore", 0, false},
		{"WrongDisk", "drill", 0, false},
		{"PeerIP", "drill", 0, false},
		{"PendingTemplate", "drill", 0, false},
		{"ReadDenied", "drill", 0, false},
		{"PreflightFailed", "drill", 0, false},
		{"BackupFailed", "drill", 0, false},
		{"NewReceipt", "drill", 0, false},
		{"PeerPreflight", "drill", 0, false},
		{"PartialWrite", "drill", 2, false},
		{"Cancelled", "drill", 2, false},
		{"PeerRestart", "drill", 2, false},
		{"PeerRollback", "drill", 2, false},
		{"ReplacedHost", "drill", 2, false},
		{"RollbackFailed", "drill", 2, false},
		{"ExternalImage", "drill", 1, false},
		{"ExternalRevision", "drill", 1, false},
		{"WrongConfirmation", "drill", 0, false},
		{"WrongWorkflow", "drill", 0, false},
	}
	for _, tc := range cases {
		t.Run(tc.operation+"/"+tc.name, func(t *testing.T) {
			t.Parallel()
			f := compiledFixture(t)
			f.env["GITHUB_WORKSPACE"], f.env["RECEIPT_BUCKET"] = f.dir, "fixture-receipts"
			f.env["GITHUB_SHA"], f.env["GITHUB_RUN_ID"], f.env["GITHUB_RUN_ATTEMPT"] = f.identity.Commit, "124", "1"
			f.env["GITHUB_REPOSITORY"], f.env["GITHUB_EVENT_NAME"], f.env["GITHUB_WORKFLOW_REF"] = "a-novel/infra", "workflow_dispatch", "a-novel/infra/.github/workflows/release.yaml@refs/heads/master"
			f.env["GITHUB_STEP_SUMMARY"] = filepath.Join(f.dir, "summary.md")
			manifest := filepath.Join(f.dir, "deploy/production/images.yaml")
			writeJSON(t, manifest, f.manifest)
			if tc.name == "MovedManifest" {
				writeJSON(t, manifest, object{})
			}
			if tc.name == "WrongWorkflow" {
				f.env["GITHUB_EVENT_NAME"] = "push"
			}
			if tc.name == "SameRevision" {
				f.env["GITHUB_SHA"] = strings.Repeat("a", 40)
			}
			args := []string{tc.operation, "123-1", strings.ToUpper(tc.operation) + " authentication", f.files[1]}
			if tc.name == "WrongReceipt" {
				args[1] = "122-1"
			}
			if tc.name == "WrongConfirmation" {
				args[2] = "DRILL json-keys"
			}
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			cloud := newIsolationCloud(t, f, tc.name, cancel)
			var output bytes.Buffer
			code := isolation.Run(ctx, args, func(key string) string { return f.env[key] }, cloud.execute, &output, &output)
			require.Equal(t, tc.success, code == 0, "%s", output.String())
			require.Equal(t, tc.mutations, cloud.mutations, "%s", output.String())
			require.NotContains(t, output.String(), privateValue)
			require.NotContains(t, output.String(), "sha256:")
			if tc.name == "WrongConfirmation" || tc.name == "WrongWorkflow" {
				require.Zero(t, cloud.calls)
				return
			}
			summary := read(t, f.env["GITHUB_STEP_SUMMARY"])
			require.Contains(t, summary, fmt.Sprintf("Exit status: %d", code))
			require.Contains(t, summary, "does not attest SQL continuity")
			if tc.success {
				require.Contains(t, summary, "Authentication restored: true; JSON Keys host unchanged: true")
				require.Equal(t, strings.Repeat("a", 40), cloud.metadata("authentication")[isolationRevision])
			}
		})
	}
}

// The coordinator's boundary is strict and offline; existing helper tests own
// snapshot freshness, logical backups, restart bounds, and guest convergence.
type isolationCloud struct {
	t *testing.T
	*releaseFixture
	scenario                      string
	cancel                        context.CancelFunc
	hosts                         map[string]object
	calls, mutations, inventories int
	proof                         string
}

func newIsolationCloud(t *testing.T, f *releaseFixture, scenario string, cancel context.CancelFunc) *isolationCloud {
	t.Helper()
	c := &isolationCloud{t: t, releaseFixture: f, scenario: scenario, cancel: cancel, hosts: map[string]object{}}
	for _, service := range []string{"authentication", "json-keys"} {
		key, prefix := strings.ReplaceAll(service, "-", "_"), strings.ReplaceAll(service, "json-keys", "jsonKeys")
		database, host := nested(f.receipt, "database"), nested(f.receipt, "database", "hosts", key)
		metadata := object{isolationRevision: host["releaseRevision"], "agora-" + service + "-database-image": database[prefix+"Image"], "agora-" + service + "-postgres-password-version": fmt.Sprint(database[prefix+"PasswordVersion"]), "agora-" + service + "-postgres-backup-password-version": fmt.Sprint(database[prefix+"BackupPasswordVersion"])}
		c.hosts[service] = object{
			"disk": host["dataDiskId"], "guest": "healthy:" + host["releaseRevision"].(string) + ":boot", "metadata": metadata,
			"vm": object{
				"name": "agora-database-" + service + "-test", "id": host["dataDiskId"], "status": "RUNNING", "lastStartTimestamp": "2026-09-14T12:00:00Z",
				"networkInterfaces": []any{object{"network": "private", "subnetwork": "private", "networkIP": host["privateIp"]}},
				"disks":             []any{object{"source": fmt.Sprintf("https://www.googleapis.com/compute/v1/projects/%s/zones/%s/disks/agora-data-%s", f.config["workload_project_id"], f.config["database_zone"], service), "deviceName": "agora-data", "boot": false, "autoDelete": false}},
			},
		}
	}
	switch scenario {
	case "MetadataDrift":
		c.metadata("authentication")["unexpected"] = privateValue
	case "WrongDisk":
		c.hosts["authentication"]["disk"] = "99"
	case "PeerIP":
		c.vm("json-keys")["networkInterfaces"].([]any)[0].(object)["networkIP"] = "10.20.0.99"
	case "Interrupted":
		c.metadata("authentication")[isolationRevision] = f.identity.Commit
		c.hosts["authentication"]["guest"] = "failed:" + f.identity.Commit + ":boot"
	}
	return c
}

func (c *isolationCloud) metadata(service string) object { return nested(c.hosts[service], "metadata") }
func (c *isolationCloud) vm(service string) object       { return nested(c.hosts[service], "vm") }

func (c *isolationCloud) execute(ctx context.Context, out io.Writer, name string, args ...string) error {
	t := c.t
	t.Helper()
	c.calls++
	require.NoError(t, ctx.Err(), "compensation must have an uncancelled context")
	fail := errors.New(privateValue)
	var value any
	if name == "infra" {
		require.Equal(t, "database-release", args[0])
		name, args = args[1], args[2:]
	}
	switch name {
	case "gcloud":
		require.GreaterOrEqual(t, len(args), 3)
		switch strings.Join(args[:3], " ") {
		case "storage objects list":
			c.inventories++
			_, err := fmt.Fprintln(out, "production/success/00000000000000000123-00001.json")
			return err
		case "storage cp gs://fixture-receipts/production/success/00000000000000000123-00001.json":
			if c.scenario == "NewReceipt" && c.inventories > 1 {
				nested(c.receipt, "sequence")["runId"] = "124"
			}
			writeJSON(t, args[3], c.receipt)
			return nil
		default:
			require.Contains(t, args, "--project="+c.config["workload_project_id"].(string))
			require.Contains(t, args, "--zone="+c.config["database_zone"].(string))
			service := "authentication"
			if strings.Contains(strings.Join(args, " "), "json-keys") {
				service = "json-keys"
			}
			switch strings.Join(args[:3], " ") {
			case "compute instance-groups managed":
				if args[3] == "list-instances" {
					_, err := fmt.Fprintln(out, c.vm(service)["name"])
					return err
				}
				require.Equal(t, "describe", args[3])
				value = object{"targetSize": 1, "status": object{"isStable": true, "versionTarget": object{"isReached": c.scenario != "PendingTemplate"}, "allInstancesConfig": object{"effective": true}}, "updatePolicy": object{"type": "OPPORTUNISTIC"}, "statefulPolicy": object{"preservedState": object{"disks": object{"agora-data": object{"autoDelete": "NEVER"}}, "internalIPs": object{"nic0": object{"autoDelete": "NEVER"}}}}, "instanceTemplate": "fixed", "versions": []string{"fixed"}, "allInstancesConfig": object{"properties": object{"metadata": c.metadata(service)}}}
			case "compute instances describe":
				if c.scenario == "ReadDenied" {
					return fail
				}
				value = c.vm(service)
			case "compute disks describe":
				_, err := fmt.Fprintln(out, c.hosts[service]["disk"])
				return err
			default:
				t.Fatalf("unexpected cloud call: %v", args)
			}
		}
	case "current":
		require.Equal(t, []string{c.config["workload_project_id"].(string), c.config["database_zone"].(string)}, args[:2])
		_, err := fmt.Fprintln(out, c.hosts[args[2]]["guest"])
		return err
	case "./ops/preflight-release.sh":
		require.Equal(t, "maintenance", readJSON(t, args[0])["mode"])
		if c.scenario == "PreflightFailed" {
			return fail
		}
		return nil
	case "prepare":
		require.Len(t, args, 7)
		c.scope(args)
		require.Equal(t, c.identity.Commit, args[4])
		c.proof = args[5]
		require.Equal(t, fmt.Sprintf("%x", sha256.Sum256([]byte(jsonText(t, c.metadata("authentication"))))), args[6])
		if c.scenario == "BackupFailed" {
			return fail
		}
		if c.scenario == "PeerPreflight" {
			c.vm("json-keys")["lastStartTimestamp"] = "changed"
		}
		return nil
	case "env":
		require.Len(t, args, 12)
		require.Equal(t, "DATABASE_CHANGE_PROOF="+c.proof, args[0])
		require.NotEmpty(t, c.proof)
		require.Equal(t, []string{"infra", "database-release", "deploy"}, args[1:4])
		c.scope(args[4:])
		require.Equal(t, c.identity.Commit, args[8])
		for index, key := range []string{"authenticationImage", "authenticationPasswordVersion", "authenticationBackupPasswordVersion"} {
			require.Equal(t, fmt.Sprint(nested(c.receipt, "database")[key]), args[9+index])
		}
		c.mutations++
		c.metadata("authentication")[isolationRevision] = c.identity.Commit
		switch c.scenario {
		case "PartialWrite":
			return fail
		case "Cancelled":
			c.cancel()
			return ctx.Err()
		case "ExternalImage":
			c.metadata("authentication")["agora-authentication-database-image"] = privateValue
			return fail
		case "ExternalRevision":
			c.metadata("authentication")[isolationRevision] = strings.Repeat("c", 40)
			return fail
		case "PeerRestart":
			c.vm("json-keys")["lastStartTimestamp"] = "changed"
		}
		return nil
	case "restore":
		require.Len(t, args, 5)
		c.scope(args)
		require.Equal(t, nested(c.receipt, "database"), readJSON(t, args[4]))
		c.mutations++
		if c.scenario == "RollbackFailed" {
			return fail
		}
		c.metadata("authentication")[isolationRevision] = strings.Repeat("a", 40)
		c.hosts["authentication"]["guest"] = "healthy:" + strings.Repeat("a", 40) + ":new-boot"
		c.vm("authentication")["lastStartTimestamp"] = "restarted"
		if c.scenario == "PeerRollback" {
			c.vm("json-keys")["lastStartTimestamp"] = "changed"
		}
		if c.scenario == "ReplacedHost" {
			c.vm("authentication")["id"] = "99"
		}
		return nil
	default:
		t.Fatalf("unexpected command: %s %v", name, args)
	}
	return json.NewEncoder(out).Encode(value)
}

func (c *isolationCloud) scope(args []string) {
	c.t.Helper()
	require.Equal(c.t, []string{c.config["workload_project_id"].(string), c.config["database_zone"].(string), "authentication", nested(c.receipt, "database", "hosts", "authentication")["dataDiskId"].(string)}, args[:4])
}

func TestIsolationWorkflow(t *testing.T) {
	t.Parallel()
	workflow := fixtureYAML[object](t, []byte(read(t, "../.github/workflows/release.yaml")))
	job := nested(workflow, "jobs", "database-isolation")
	require.Equal(t, object{"group": "production-infrastructure", "cancel-in-progress": false}, workflow["concurrency"])
	require.Equal(t, "production-release", job["environment"])
	require.Equal(t, object{"contents": "read", "id-token": "write"}, job["permissions"])
	require.Contains(t, job["if"], "github.event_name == 'workflow_dispatch'")
	require.Contains(t, job["if"], "refs/heads/master")
	require.Contains(t, nested(workflow, "jobs", "release")["if"], "!endsWith(inputs.action, '-database-isolation')")
	encoded := jsonText(t, job)
	require.Contains(t, encoded, "infra database-isolation")
	for _, forbidden := range []string{"tofu", "compute ssh", "add-iam", "infra custody receipt publish"} {
		require.NotContains(t, encoded, forbidden)
	}
}
