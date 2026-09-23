package workflow_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"testing"

	"github.com/a-novel/infra/internal/workflow"
)

const (
	sha      = "1111111111111111111111111111111111111111"
	head     = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	runURL   = "https://github.com/a-novel/infra/actions/runs/202"
	dispatch = `{"workflow_run_id":202,"html_url":"` + runURL + `"}`
)

type result struct {
	code           int
	stdout, stderr bytes.Buffer
	dispatches     [][]string
	watches        int
	calls          int
}

func invoke(t *testing.T, args []string, overrides map[string]string, failAt string) result {
	t.Helper()
	r := result{}
	readRuns := 0
	r.code = workflow.Run(t.Context(), args, func(ctx context.Context, output io.Writer, name string, command ...string) error {
		r.calls++
		if err := ctx.Err(); err != nil {
			return err
		}
		stage := ""
		body := ""
		switch {
		case name == "git":
			stage = command[0]
			body = map[string]string{"branch": "master", "status": "", "rev-parse": sha}[stage]
		case command[0] == "run":
			stage, body = "watch", "Watch progress"
			r.watches++
		case strings.HasSuffix(command[1], "/commits/master"):
			stage, body = "remote", sha
		case strings.HasSuffix(command[1], "/pulls/93"):
			stage, body = "pr", `{"state":"open","base":{"ref":"master","sha":"`+sha+
				`","repo":{"full_name":"a-novel/infra"}},"head":{"sha":"`+head+`"}}`
		case strings.Contains(command[1], "?branch=master"):
			stage = "active"
		case strings.HasSuffix(command[1], "/dispatches"):
			stage, body = "dispatch", dispatch
			r.dispatches = append(r.dispatches, command)
		case strings.Contains(command[1], "/actions/runs/"):
			stage = "plan"
			if strings.HasSuffix(command[1], "/202") {
				stage = "run"
				if readRuns > 0 {
					stage = "finished"
				}
				readRuns++
			}
			title := "foundation plan foundation by @operator"
			switch args[0] {
			case "foundation":
				scope := args[2]
				if scope == "service-foundation" {
					scope += "/" + args[3]
				}
				title = "foundation plan " + scope + " by @operator"
			case "recovery":
				title = "recovery plan-workload " + args[2] + " by @operator"
			}
			body = fmt.Sprintf(`{"id":202,"run_attempt":3,"head_sha":%q,"head_branch":"master",`+
				`"path":%q,"display_title":%q,"event":"workflow_dispatch","status":"completed","conclusion":"success"}`,
				sha, ".github/workflows/"+args[0]+".yaml", title)
		default:
			panic("unexpected command: " + name + " " + strings.Join(command, " "))
		}
		if stage == failAt {
			return errors.New("simulated command failure")
		}
		if value, ok := overrides[stage]; ok {
			body = value
		}
		if patch, ok := overrides[stage+".patch"]; ok {
			values, changes := map[string]any{}, map[string]any{}
			if err := json.Unmarshal([]byte(body), &values); err != nil {
				panic(err)
			}
			if err := json.Unmarshal([]byte(patch), &changes); err != nil {
				panic(err)
			}
			for key, value := range changes {
				values[key] = value
			}
			encoded, err := json.Marshal(values)
			if err != nil {
				panic(err)
			}
			body = string(encoded)
		}
		_, err := io.WriteString(output, body)
		return err
	}, &r.stdout, &r.stderr)
	return r
}
