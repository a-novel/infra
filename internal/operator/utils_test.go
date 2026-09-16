package operator_test

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"slices"
	"strings"
	"testing"

	"github.com/a-novel/infra/internal/operator"
)

type result struct {
	code           int
	stdout, stderr bytes.Buffer
	calls          [][]string
}

func invoke(t *testing.T, args []string, directory string, env, responses map[string]string, failure string) result {
	t.Helper()
	r := result{}
	getenv := func(key string) string {
		if value, ok := env[key]; ok {
			return value
		}
		return map[string]string{"HOME": directory, "INFRA_MANAGEMENT_PROJECT_ID": "management-project-prod", "INFRA_WORKLOAD_PROJECT_ID": "workload-project-prod"}[key]
	}
	r.code = operator.Run(t.Context(), args, getenv, func(ctx context.Context, output io.Writer, name string, command ...string) error {
		r.calls = append(r.calls, append([]string{name}, command...))
		if err := ctx.Err(); err != nil {
			return err
		}
		stage, body := "", ""
		switch name {
		case "gh":
			if !slices.Equal(command, []string{"variable", "list", "--repo", "a-novel/infra", "--json", "name,value"}) {
				panic(command)
			}
			stage, body = "variables", `[{"name":"GCP_MANAGEMENT_PROJECT_ID","value":"management-project-prod"},{"name":"GCP_WORKLOAD_PROJECT_ID","value":"workload-project-prod"}]`
		case "ssh-keygen":
			stage = "keygen"
			if failure != stage {
				key := command[len(command)-1]
				if err := os.WriteFile(key, []byte("private-fixture-never-print"), 0o600); err != nil {
					panic(err)
				}
				if err := os.WriteFile(key+".pub", []byte("ssh-ed25519 fixture\n"), 0o600); err != nil {
					panic(err)
				}
			}
		case "gcloud":
			if !slices.Contains(command, "--project=workload-project-prod") {
				panic(command)
			}
			service, instance, ip, disk := "authentication", "agora-database-authentication-test", "10.20.0.2", "1001"
			if strings.Contains(strings.Join(command, " "), "json-keys") {
				service, instance, ip, disk = "json-keys", "agora-database-json-keys-test", "10.20.0.3", "1002"
			}
			switch {
			case slices.Contains(command, "--format=value(zone.basename())"):
				stage, body = "zone:"+service, "europe-west1-d"
			case slices.Contains(command, "--format=value(instance.basename())"):
				stage, body = "instance:"+service, instance
			case slices.Contains(command, "--format=value(networkInterfaces[0].networkIP)"):
				stage, body = "ip:"+service, ip
			case slices.Contains(command, "--format=value(id)"):
				stage, body = "disk:"+service, disk
			case command[1] == "ssh":
				stage = "ssh"
			case slices.Contains(command, "describe"), slices.Contains(command, "list"):
				stage = "inspection"
			default:
				panic(command)
			}
		default:
			panic(name)
		}
		if stage == failure {
			return errors.New("simulated command failure")
		}
		if value, ok := responses[stage]; ok {
			body = value
		}
		_, err := io.WriteString(output, body)
		return err
	}, &r.stdout, &r.stderr)
	return r
}
