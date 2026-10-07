package tests_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"strings"
	"testing"
	"testing/synctest"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/a-novel/infra/internal/database"
)

func TestDatabaseReadiness(t *testing.T) {
	t.Parallel()
	for _, scenario := range []string{"NewBoot", "OldBoot", "OldBootFailed", "OldBootFailedThenNew", "OldBootChangedRevision", "InitialBoot", "Absent", "Failed", "Cancelled", "MultipleHosts"} {
		t.Run(scenario, func(t *testing.T) {
			t.Parallel()
			synctest.Test(t, func(t *testing.T) {
				c := newDatabaseCloud(t, "json-keys")
				previous := "healthy:" + c.metadata[isolationRevision] + ":11111111-1111-1111-1111-111111111111"
				c.statuses = []string{previous, strings.ReplaceAll(previous, "11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222")}
				switch scenario {
				case "OldBoot":
					c.statuses = []string{previous}
				case "OldBootFailed", "OldBootFailedThenNew":
					c.statuses[0] = strings.Replace(previous, "healthy:", "failed:", 1)
					if scenario == "OldBootFailed" {
						c.statuses = c.statuses[:1]
					}
				case "OldBootChangedRevision":
					c.statuses = []string{previous}
					previous = strings.Replace(previous, c.metadata[isolationRevision], strings.Repeat("f", 40), 1)
				case "InitialBoot":
					previous = "absent"
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
				require.Equal(t, scenario == "NewBoot" || scenario == "OldBootFailedThenNew" || scenario == "InitialBoot", code == 0, c.output.String())
				if scenario == "OldBoot" || scenario == "OldBootFailed" || scenario == "OldBootChangedRevision" {
					require.Equal(t, 595*time.Second, time.Since(started))
					require.Len(t, c.calls, 87)
				}
				if scenario == "NewBoot" || scenario == "OldBootFailedThenNew" {
					require.Equal(t, 7*time.Second, time.Since(started))
				}
				if scenario == "Failed" || scenario == "InitialBoot" {
					require.Zero(t, time.Since(started))
				}
			})
		})
	}
}

const isolationRevision = "agora-database-release-revision"

func TestRetiredDatabaseCommands(t *testing.T) {
	t.Parallel()
	for _, action := range []string{"prepare", "deploy", "restore", "recover-first-launch"} {
		t.Run(action, func(t *testing.T) {
			t.Parallel()
			cloud := newDatabaseCloud(t, "authentication")
			expectCode(t, 64, cloud.run(t, action, "1001", strings.Repeat("a", 40)), cloud.output.String())
			require.Empty(t, cloud.calls)
		})
	}
}

type databaseCloud struct {
	t *testing.T
	*sandbox
	service, project, zone, disk, fail, cancelAt string
	metadata                                     map[string]string
	calls, statuses                              []string
	writes                                       int
	multiple                                     bool
	cancel                                       context.CancelFunc
	output                                       bytes.Buffer
}

func newDatabaseCloud(t *testing.T, service string) *databaseCloud {
	t.Helper()
	c := &databaseCloud{t: t, sandbox: setup(t), service: service, project: "agora-production-test", zone: "europe-west1-c", disk: "1001"}
	if service == "json-keys" {
		c.disk = "1002"
	}
	c.metadata = map[string]string{
		isolationRevision:                                        strings.Repeat("a", 40),
		"agora-" + service + "-database-image":                   "europe-west1-docker.pkg.dev/" + c.project + "/agora-production/service-" + service + "/database@sha256:" + strings.Repeat("1", 64),
		"agora-" + service + "-postgres-password-version":        "1",
		"agora-" + service + "-postgres-backup-password-version": "2",
	}
	return c
}

func (c *databaseCloud) run(t *testing.T, action string, args ...string) int {
	t.Helper()
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	c.cancel = cancel
	base := []string{action, c.project, c.zone, c.service}
	code := database.Run(ctx, append(base, args...), func(key string) string { return c.env[key] }, c.execute, &c.output, &c.output)
	require.NotContains(t, c.output.String(), privateValue)
	require.NotContains(t, c.output.String(), "sha256:")
	return code
}

func (c *databaseCloud) execute(ctx context.Context, out io.Writer, name string, args ...string) error {
	t := c.t
	t.Helper()
	require.NoError(t, ctx.Err())
	require.Equal(t, "gcloud", name)
	require.GreaterOrEqual(t, len(args), 3)
	var value any
	key, operation := strings.Join(args[:3], " "), ""
	require.Contains(t, args, "--project="+c.project)
	require.Contains(t, args, "--zone="+c.zone)
	switch key {
	case "compute disks describe":
		require.Equal(t, "agora-data-"+c.service, args[3])
		operation, value = "disk", c.disk
	case "compute instance-groups managed":
		operation = args[3]
		target := args[4]
		require.Equal(t, "agora-database-"+c.service, target)
		switch operation {
		case "describe":
			operation, value = "metadata", object{"allInstancesConfig": object{"properties": object{"metadata": c.metadata}}}
		case "list-instances":
			operation, value = "instance", "agora-database-"+c.service+"-test"
			if c.multiple {
				value = value.(string) + "\n" + value.(string)
			}
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
