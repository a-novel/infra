package automation_test

import (
	"bytes"
	"context"
	"crypto/sha1"
	"encoding/base64"
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

const (
	head         = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	base         = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	trusted      = "cccccccccccccccccccccccccccccccccccccccc"
	mainPath     = ".github/workflows/main.yaml"
	manifestPath = "deploy/production/images.yaml"
	before       = "2026-09-07T01:00:00Z"
	changed      = "2026-09-07T01:01:00Z"
	after        = "2026-09-07T01:02:00Z"
)

type object = map[string]any

type fixture struct {
	t                           *testing.T
	routes                      map[string]any
	env                         map[string]string
	event, pull, ci, assessment object
	jobs                        []object
	posts                       []string
	before                      func(string, string) error
	reads                       map[string]int
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	repo := object{"full_name": "a-novel/infra"}
	pull := object{
		"number": 42, "state": "open", "draft": false, "changed_files": 1,
		"user": object{"login": "anovelbot-dependencies[bot]", "type": "Bot"},
		"base": object{"ref": "master", "sha": base, "repo": repo},
		"head": object{"ref": "renovate/authentication", "sha": head, "repo": repo},
	}
	ci := object{
		"id": 100, "workflow_id": 50, "path": mainPath, "event": "pull_request", "repository": repo, "head_repository": repo,
		"head_branch": "renovate/authentication", "head_sha": head, "status": "completed", "conclusion": "failure", "run_attempt": 1,
	}
	assessment := object{
		"id": 300, "workflow_id": 60, "run_attempt": 1, "path": ".github/workflows/drift.yaml", "repository": repo, "head_repository": repo,
		"event": "workflow_dispatch", "head_branch": "master", "head_sha": base, "status": "completed", "conclusion": "success", "updated_at": changed,
		"display_title": "resource-deletion assessment PR #42 " + head + " onto " + base,
	}
	f := &fixture{
		t: t, pull: pull, ci: ci, assessment: assessment, routes: make(map[string]any), reads: make(map[string]int),
		env: map[string]string{
			"GITHUB_REPOSITORY": "a-novel/infra", "GITHUB_EVENT_NAME": "workflow_run", "GITHUB_REF": "refs/heads/master", "GITHUB_SHA": base,
			"PULL_REQUEST": "42", "HEAD_SHA": head, "BASE_SHA": base, "GITHUB_EVENT_PATH": filepath.Join(t.TempDir(), "event.json"),
		},
		event: object{"action": "completed", "repository": repo, "workflow_run": object{"id": 100}},
	}
	f.routes["/pulls/42"] = pull
	f.routes["/pulls?state=open&base=master&per_page=100"] = pages("", []object{pull})
	f.routes["/commits/"+head+"/pulls?per_page=100"] = pages("", []object{pull})
	f.routes["/pulls/42/files?per_page=100"] = pages("", []object{{"filename": manifestPath, "status": "modified"}})
	f.routes["/actions/workflows/main.yaml"] = object{"id": 50, "path": mainPath}
	f.routes["/actions/workflows/drift.yaml"] = object{"id": 60, "path": ".github/workflows/drift.yaml"}
	f.routes["/actions/runs/100"] = ci
	f.routes["/actions/runs/300"] = assessment
	f.routes["/actions/workflows/main.yaml/runs?event=pull_request&head_sha="+head+"&per_page=100"] = pages("workflow_runs", []object{ci})
	f.routes["/actions/workflows/main.yaml/runs?head_sha="+head+"&per_page=100"] = pages("workflow_runs", []object{ci})
	f.routes["/actions/workflows/drift.yaml/runs?branch=master&event=workflow_dispatch&per_page=100"] = pages("workflow_runs", []object{})
	f.routes["/actions/workflows/drift.yaml/runs?branch=master&event=workflow_dispatch&head_sha="+base+"&per_page=100"] = pages("workflow_runs", []object{assessment})
	f.routes["/git/ref/heads/master"] = object{"object": object{"sha": base}}
	f.routes["/contents/"+mainPath+"?ref="+head] = object{"sha": trusted}
	f.routes["/issues/42/events?per_page=100"] = pages("", []object{})
	for i, name := range []string{"validate-opentofu", "scan-infrastructure", "lint-repository", "resource-deletion-gate"} {
		f.jobs = append(f.jobs, object{"id": 1000 + i, "run_id": 100, "run_attempt": 1, "name": name, "status": "completed", "conclusion": "success", "started_at": before})
	}
	f.jobs[3]["conclusion"] = "failure"
	f.routes["/actions/runs/100/jobs?filter=latest&per_page=100"] = pages("jobs", f.jobs)
	f.routes["/actions/runs/100/attempts/1/jobs?per_page=100"] = pages("jobs", f.jobs)
	for _, sha := range []string{head, base} {
		f.routes["/git/trees/"+sha+"?recursive=1"] = object{"truncated": false, "tree": []object{}}
		f.blob(sha, mainPath, "trusted workflow")
	}
	f.blob(base, manifestPath, manifest("v1.0.0"))
	f.blob(head, manifestPath, manifest("v1.0.1"))
	return f
}

func manifest(tag string) string {
	return "components:\n  example:\n    enabled: true\n    images:\n      rest:\n        repository: ghcr.io/a-novel/example/rest\n        tag: " + tag + "\n        digest: sha256:" + strings.Repeat("1", 64) + "\n"
}

func pages(key string, values []object) []any {
	if key == "" {
		return []any{[]object{}, values}
	}
	return []any{object{key: []object{}}, object{key: values}}
}

func (f *fixture) blob(commit, path, value string) object {
	f.t.Helper()
	sha := fmt.Sprintf("%x", sha1.Sum([]byte(fmt.Sprintf("blob %d\x00%s", len(value), value))))
	blob := object{"sha": sha, "size": len(value), "encoding": "base64", "content": base64.StdEncoding.EncodeToString([]byte(value))}
	f.routes["/git/blobs/"+sha] = blob
	tree := f.routes["/git/trees/"+commit+"?recursive=1"].(object)
	entries := tree["tree"].([]object)
	entry := object{"path": path, "sha": sha, "mode": "100644", "type": "blob", "size": len(value)}
	for i, old := range entries {
		if old["path"] == path {
			entries[i] = entry
			return blob
		}
	}
	tree["tree"] = append(entries, entry)
	return blob
}

func (f *fixture) execute(_ context.Context, output io.Writer, name string, args ...string) error {
	f.t.Helper()
	if name == "git" {
		require.Equal(f.t, "rev-parse", args[0])
		value := base
		if args[1] == "HEAD:"+mainPath {
			value = trusted
		} else {
			require.Equal(f.t, "HEAD", args[1])
		}
		_, err := fmt.Fprintln(output, value)
		return err
	}
	require.Equal(f.t, "gh", name)
	require.Equal(f.t, "api", args[0])
	require.True(f.t, strings.HasPrefix(args[1], "repos/a-novel/infra/"))
	path, method := strings.TrimPrefix(args[1], "repos/a-novel/infra"), args[3]
	require.NotRegexp(f.t, `artifacts|logs|secrets|check-runs`, path)
	f.reads[path]++
	if f.before != nil {
		if err := f.before(path, method); err != nil {
			return err
		}
	}
	if method == "POST" {
		f.posts = append(f.posts, strings.Join(args[1:], " "))
		return nil
	}
	require.Equal(f.t, "GET", method)
	value, ok := f.routes[path]
	require.True(f.t, ok, "unexpected API path: %s", path)
	if _, paginated := value.([]any); paginated {
		require.Equal(f.t, []string{"--paginate", "--slurp"}, args[4:])
	}
	if raw, ok := value.(string); ok {
		_, err := io.WriteString(output, raw)
		return err
	}
	return json.NewEncoder(output).Encode(value)
}

func (f *fixture) run(args ...string) (int, string) {
	f.t.Helper()
	data, err := json.Marshal(f.event)
	require.NoError(f.t, err)
	require.NoError(f.t, os.WriteFile(f.env["GITHUB_EVENT_PATH"], data, 0o600))
	var stdout, stderr bytes.Buffer
	code := automation.Run(f.t.Context(), args, func(key string) string { return f.env[key] }, f.execute, &stdout, &stderr)
	return code, stdout.String() + stderr.String()
}

func TestImageAssessment(t *testing.T) {
	t.Parallel()
	tests := map[string]struct {
		mutate func(*fixture)
		accept bool
	}{
		"validated update despite red gate":          {accept: true},
		"successful jobs from earlier partial rerun": {mutate: func(f *fixture) { f.ci["run_attempt"] = 2 }, accept: true},
		"digest only": {mutate: func(f *fixture) {
			f.blob(head, manifestPath, strings.ReplaceAll(manifest("v1.0.0"), strings.Repeat("1", 64), strings.Repeat("2", 64)))
		}, accept: true},
		"human":              {mutate: func(f *fixture) { f.pull["user"] = object{"login": "maintainer", "type": "User"} }},
		"other bot":          {mutate: func(f *fixture) { f.pull["user"].(object)["login"] = "renovate[bot]" }},
		"fork":               {mutate: func(f *fixture) { f.pull["head"].(object)["repo"] = object{"full_name": "another/repo"} }},
		"draft":              {mutate: func(f *fixture) { f.pull["draft"] = true }},
		"missing draft flag": {mutate: func(f *fixture) { delete(f.pull, "draft") }},
		"closed":             {mutate: func(f *fixture) { f.pull["state"] = "closed" }},
		"stale base":         {mutate: func(f *fixture) { f.pull["base"].(object)["sha"] = trusted }},
		"extra changed file": {mutate: func(f *fixture) { f.pull["changed_files"] = 2 }},
		"renamed manifest": {mutate: func(f *fixture) {
			f.routes["/pulls/42/files?per_page=100"] = pages("", []object{{"filename": manifestPath, "status": "modified", "previous_filename": "other"}})
		}},
		"truncated tree": {mutate: func(f *fixture) { f.routes["/git/trees/"+head+"?recursive=1"].(object)["truncated"] = true }},
		"symlink": {mutate: func(f *fixture) {
			f.routes["/git/trees/"+head+"?recursive=1"].(object)["tree"].([]object)[1]["mode"] = "120000"
		}},
		"changed CI workflow":  {mutate: func(f *fixture) { f.blob(head, mainPath, "unreviewed workflow") }},
		"corrupt blob":         {mutate: func(f *fixture) { f.blob(head, manifestPath, manifest("v1.0.1"))["content"] = "Zm9v" }},
		"invalid UTF8":         {mutate: func(f *fixture) { f.blob(head, manifestPath, "\xff") }},
		"push CI only":         {mutate: func(f *fixture) { f.ci["event"] = "push" }},
		"wrong workflow":       {mutate: func(f *fixture) { f.ci["workflow_id"] = 51 }},
		"running CI":           {mutate: func(f *fixture) { f.ci["status"] = "in_progress" }},
		"failed lint":          {mutate: func(f *fixture) { f.jobs[2]["conclusion"] = "failure" }},
		"skipped scan":         {mutate: func(f *fixture) { f.jobs[1]["conclusion"] = "skipped" }},
		"missing validation":   {mutate: func(f *fixture) { f.jobs[0]["name"] = "unrelated" }},
		"duplicate validation": {mutate: func(f *fixture) { f.jobs[3]["name"] = "lint-repository" }},
		"wrong attempt":        {mutate: func(f *fixture) { f.jobs[0]["run_attempt"] = 2 }},
		"wrong run":            {mutate: func(f *fixture) { f.jobs[0]["run_id"] = 101 }},
		"master moved":         {mutate: func(f *fixture) { f.routes["/git/ref/heads/master"] = object{"object": object{"sha": trusted}} }},
		"head moved after validation": {mutate: func(f *fixture) {
			f.before = func(path, _ string) error {
				if path == "/pulls/42" && f.reads[path] == 2 {
					f.pull["head"].(object)["sha"] = trusted
				}
				return nil
			}
		}},
		"attempt changed during validation": {mutate: func(f *fixture) {
			f.before = func(path, _ string) error {
				if path == "/actions/runs/100" && f.reads[path] == 2 {
					f.ci["run_attempt"] = 2
				}
				return nil
			}
		}},
	}
	for name, value := range map[string]string{
		"identical": manifest("v1.0.0"), "repository": strings.ReplaceAll(manifest("v1.0.1"), "ghcr.io", "attacker.invalid"),
		"enabled": strings.ReplaceAll(manifest("v1.0.1"), "true", "false"), "structure": strings.ReplaceAll(manifest("v1.0.1"), "example:", "other:"),
		"extra comment": manifest("v1.0.1") + "#extra\n", "anchor": manifest("&tag v1.0.1"), "command": manifest("$(id)"), "prerelease": manifest("v1.0.1-rc.1"), "oversized": strings.Repeat("x", 65537),
	} {
		tests[name] = struct {
			mutate func(*fixture)
			accept bool
		}{mutate: func(f *fixture) { f.blob(head, manifestPath, value) }}
	}
	for name, tt := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			f := newFixture(t)
			if tt.mutate != nil {
				tt.mutate(f)
			}
			code, output := f.run("assess-images", "verify")
			require.Equal(t, tt.accept, code == 0, output)
			require.Empty(t, f.posts)
		})
	}
}

func TestAssessmentDispatch(t *testing.T) {
	t.Parallel()
	for name, tt := range map[string]struct {
		mutate func(*fixture)
		count  int
	}{
		"validated": {count: 1},
		"master completion": {mutate: func(f *fixture) {
			trigger := maps.Clone(f.ci)
			trigger["id"], trigger["event"], trigger["head_sha"], trigger["head_branch"], trigger["conclusion"] = 200, "push", base, "master", "success"
			f.routes["/actions/runs/200"], f.event["workflow_run"] = trigger, object{"id": 200}
		}, count: 1},
		"assessment completion": {mutate: func(f *fixture) { f.event["workflow_run"] = object{"id": 300} }, count: 1},
		"untrusted completion":  {mutate: func(f *fixture) { f.event["repository"] = object{"full_name": "other/repo"} }},
		"active assessment serializes": {mutate: func(f *fixture) {
			f.assessment["status"] = "queued"
			f.routes["/actions/workflows/drift.yaml/runs?branch=master&event=workflow_dispatch&per_page=100"] = pages("workflow_runs", []object{f.assessment})
		}},
		"failed exact tuple not retried": {mutate: func(f *fixture) {
			f.assessment["conclusion"] = "failure"
			f.routes["/actions/workflows/drift.yaml/runs?branch=master&event=workflow_dispatch&per_page=100"] = pages("workflow_runs", []object{f.assessment})
		}},
		"old tuple does not block": {mutate: func(f *fixture) {
			f.assessment["display_title"] = "old tuple"
			f.routes["/actions/workflows/drift.yaml/runs?branch=master&event=workflow_dispatch&per_page=100"] = pages("workflow_runs", []object{f.assessment})
		}, count: 1},
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			f := newFixture(t)
			if tt.mutate != nil {
				tt.mutate(f)
			}
			code, output := f.run("assess-images", "dispatch")
			require.Zero(t, code, output)
			require.Len(t, f.posts, tt.count)
			if tt.count == 1 {
				require.Equal(t, "repos/a-novel/infra/actions/workflows/drift.yaml/dispatches --method POST -f ref=master -f inputs[operation]=assess-image-update -f inputs[pull_request]=42 -f inputs[head_sha]="+head+" -f inputs[base_sha]="+base, f.posts[0])
			}
		})
	}
}

func TestGateRefresh(t *testing.T) {
	t.Parallel()
	for name, tt := range map[string]struct {
		mutate func(*fixture)
		count  int
		fail   bool
	}{
		"assessment":                   {count: 1},
		"already green":                {mutate: func(f *fixture) { f.jobs[3]["conclusion"] = "success" }, count: 1},
		"failed assessment":            {mutate: func(f *fixture) { f.assessment["conclusion"] = "failure" }, count: 1},
		"same second":                  {mutate: func(f *fixture) { f.jobs[3]["started_at"] = changed }, count: 1},
		"already refreshed":            {mutate: func(f *fixture) { f.jobs[3]["started_at"] = after }},
		"active CI":                    {mutate: func(f *fixture) { f.ci["status"] = "in_progress" }},
		"wrong candidate branch":       {mutate: func(f *fixture) { f.ci["head_branch"] = "another-branch" }},
		"wrong workflow ID":            {mutate: func(f *fixture) { f.ci["workflow_id"] = 51 }},
		"closed PR":                    {mutate: func(f *fixture) { f.pull["state"] = "closed" }},
		"stale assessment":             {mutate: func(f *fixture) { f.assessment["display_title"] = "old tuple" }},
		"wrong assessment base":        {mutate: func(f *fixture) { f.assessment["head_sha"] = trusted }},
		"different candidate workflow": {mutate: func(f *fixture) { f.routes["/contents/"+mainPath+"?ref="+head] = object{"sha": head} }, fail: true},
		"wrong gate attempt":           {mutate: func(f *fixture) { f.jobs[3]["run_attempt"] = 2 }, fail: true},
		"wrong gate run":               {mutate: func(f *fixture) { f.jobs[3]["run_id"] = 101 }, fail: true},
		"malformed timestamp":          {mutate: func(f *fixture) { f.jobs[3]["started_at"] = "yesterday" }, fail: true},
		"PR moved before POST": {mutate: func(f *fixture) {
			f.before = func(path, _ string) error {
				if path == "/pulls/42" && f.reads[path] == 2 {
					f.pull["head"].(object)["sha"] = trusted
				}
				return nil
			}
		}},
		"POST denied": {mutate: func(f *fixture) {
			f.before = func(_, method string) error {
				if method == "POST" {
					return errors.New("private canary")
				}
				return nil
			}
		}, fail: true},
		"concurrent rerun": {mutate: func(f *fixture) {
			f.before = func(_, method string) error {
				if method == "POST" {
					f.ci["status"] = "queued"
					return errors.New("already queued")
				}
				return nil
			}
		}},
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			f := newFixture(t)
			f.event["workflow_run"] = object{"id": 300}
			if tt.mutate != nil {
				tt.mutate(f)
			}
			code, output := f.run("refresh-deletion-gates")
			require.Equal(t, tt.fail, code != 0, output)
			require.NotContains(t, output, "private canary")
			require.Len(t, f.posts, tt.count)
			if tt.count == 1 {
				require.Equal(t, "repos/a-novel/infra/actions/jobs/1003/rerun --method POST", f.posts[0])
			}
		})
	}
}
