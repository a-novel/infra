package automation_test

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"maps"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/a-novel/infra/internal/automation"
)

func TestRefreshNotifications(t *testing.T) {
	t.Parallel()
	for _, action := range []string{"labeled", "unlabeled", "CI completion"} {
		t.Run(action, func(t *testing.T) {
			t.Parallel()
			f := newFixture(t)
			f.routes["/actions/workflows/drift.yaml/runs?branch=master&event=workflow_dispatch&head_sha="+base+"&per_page=100"] = pages("workflow_runs", []object{})
			f.routes["/issues/42/events?per_page=100"] = pages("", []object{{"event": "unlabeled", "label": object{"name": "allow-resource-deletion"}, "created_at": changed}})
			if action != "CI completion" {
				f.env["GITHUB_EVENT_NAME"] = "pull_request_target"
				f.event["action"], f.event["label"], f.event["pull_request"] = action, object{"name": "allow-resource-deletion"}, f.pull
			}
			push := maps.Clone(f.ci)
			push["id"], push["event"] = 101, "push"
			f.routes["/actions/runs/101"] = push
			gate := maps.Clone(f.jobs[3])
			gate["id"], gate["run_id"] = 1010, 101
			f.routes["/actions/runs/101/attempts/1/jobs?per_page=100"] = pages("jobs", []object{gate})
			f.routes["/actions/workflows/main.yaml/runs?head_sha="+head+"&per_page=100"] = pages("workflow_runs", []object{f.ci, push})
			f.env["GITHUB_STEP_SUMMARY"] = filepath.Join(t.TempDir(), "summary")
			code, output := f.run("refresh-deletion-gates")
			require.Zero(t, code, output)
			require.Len(t, f.posts, 2)
			summary, err := os.ReadFile(f.env["GITHUB_STEP_SUMMARY"])
			require.NoError(t, err)
			require.Equal(t, output, string(summary))
			f.jobs[3]["started_at"], gate["started_at"] = after, after
			code, output = f.run("refresh-deletion-gates")
			require.Zero(t, code, output)
			require.Len(t, f.posts, 2, "duplicate notification must not create a loop")
		})
	}
}

func TestRefreshRequiresNewEvidence(t *testing.T) {
	t.Parallel()
	for name, mutate := range map[string]func(*fixture){
		"ordinary CI": func(f *fixture) {
			f.routes["/actions/workflows/drift.yaml/runs?branch=master&event=workflow_dispatch&head_sha="+base+"&per_page=100"] = pages("workflow_runs", []object{})
		},
		"ambiguous PR association": func(f *fixture) {
			f.routes["/commits/"+head+"/pulls?per_page=100"] = pages("", []object{f.pull, f.pull})
		},
		"newer active CI blocks older attempt": func(f *fixture) {
			newest := maps.Clone(f.ci)
			newest["id"], newest["status"] = 200, "queued"
			f.routes["/actions/runs/200"] = newest
			f.routes["/actions/workflows/main.yaml/runs?head_sha="+head+"&per_page=100"] = pages("workflow_runs", []object{f.ci, newest})
		},
		"unrelated label": func(f *fixture) {
			f.env["GITHUB_EVENT_NAME"] = "pull_request_target"
			f.event["action"], f.event["label"] = "labeled", object{"name": "unrelated"}
		},
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			f := newFixture(t)
			mutate(f)
			code, output := f.run("refresh-deletion-gates")
			require.Zero(t, code, output)
			require.Empty(t, f.posts)
		})
	}
}

func TestRemoteErrorsStayPrivate(t *testing.T) {
	t.Parallel()
	for name, value := range map[string]string{"read failure": "", "invalid JSON": "private-canary", "oversized response": strings.Repeat("x", 16<<20) + "private-canary"} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			f := newFixture(t)
			f.routes["/pulls/42"] = value
			if value == "" {
				f.before = func(_, _ string) error { return errors.New("private-canary") }
			}
			code, output := f.run("assess-images", "verify")
			require.NotZero(t, code)
			require.NotContains(t, output, "private-canary")
			require.Empty(t, f.posts)
		})
	}
}

func TestInvalidInvocation(t *testing.T) {
	t.Parallel()
	for _, args := range [][]string{nil, {"assess-images"}, {"assess-images", "unknown"}, {"refresh-deletion-gates", "extra"}} {
		t.Run(strings.Join(args, "/"), func(t *testing.T) {
			t.Parallel()
			var output strings.Builder
			code := automation.Run(t.Context(), args, func(string) string { return "" }, func(context.Context, io.Writer, string, ...string) error {
				t.Fatal("invalid intent must not execute a command")
				return nil
			}, &output, &output)
			require.Equal(t, 64, code)
		})
	}
}

func TestMetadataBufferLimit(t *testing.T) {
	t.Parallel()
	for _, stream := range []bool{false, true} {
		t.Run(fmt.Sprint(stream), func(t *testing.T) {
			t.Parallel()
			f := newFixture(t)
			f.pull["unused"] = strings.Repeat("x", 16<<20)
			data, err := json.Marshal(f.pull)
			require.NoError(t, err)
			payload := string(data)
			calls := 0
			execute := func(_ context.Context, output io.Writer, _ string, _ ...string) error {
				calls++
				if stream {
					_, err := io.Copy(output, struct{ io.Reader }{strings.NewReader(payload)})
					return err
				}
				_, err := io.WriteString(output, payload)
				return err
			}
			var output strings.Builder
			code := automation.Run(t.Context(), []string{"assess-images", "verify"}, func(key string) string { return f.env[key] }, execute, &output, &output)
			require.Equal(t, 70, code)
			require.Equal(t, 1, calls, "oversized but valid JSON must fail before further reads")
		})
	}
}
