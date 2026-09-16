package workflow

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"strconv"
	"strings"
)

const (
	repository = "a-novel/infra"
	api        = "repos/" + repository
	actionsURL = "https://github.com/" + repository + "/actions"
)

type run struct {
	ID         int64  `json:"id"`
	Attempt    int64  `json:"run_attempt"`
	SHA        string `json:"head_sha"`
	Branch     string `json:"head_branch"`
	Path       string `json:"path"`
	Title      string `json:"display_title"`
	Event      string `json:"event"`
	Status     string `json:"status"`
	Conclusion string `json:"conclusion"`
}

// Run validates an operator command, invokes Git and GitHub CLI through execute,
// and returns its exit code. stdout receives only a verified run or run-attempt ID;
// stderr carries progress and bounded diagnostics. execute must pass arguments
// literally and route child diagnostics to stderr.
func Run(ctx context.Context, args []string, execute func(context.Context, io.Writer, string, ...string) error, stdout, stderr io.Writer) int {
	stop := func(code int, message string) int {
		_, _ = fmt.Fprintln(stderr, message)
		return code
	}
	i, err := parse(args)
	if err != nil {
		return stop(64, err.Error())
	}
	read := func(name string, args ...string) (string, error) {
		var output bytes.Buffer
		err := execute(ctx, &output, name, args...)
		return strings.TrimSpace(output.String()), err
	}
	readJSON := func(endpoint string, target any) error {
		body, err := read("gh", "api", api+endpoint)
		if err != nil {
			return err
		}
		return json.Unmarshal([]byte(body), target)
	}
	branch, err := read("git", "branch", "--show-current")
	if err != nil || branch != "master" {
		return stop(65, "Run protected workflows only from the local master branch.")
	}
	dirty, err := read("git", "status", "--porcelain")
	if err != nil || dirty != "" {
		return stop(65, "Run protected workflows only from a clean checkout.")
	}
	sha, err := read("git", "rev-parse", "HEAD")
	if err != nil || !matches(`[a-f0-9]{40}`, sha) {
		return stop(65, "Cannot determine the local master commit.")
	}
	if i.planID != "" {
		parts := strings.Split(i.planID, "-")
		attempt, parseErr := strconv.ParseInt(parts[1], 10, 64)
		var plan run
		if err := readJSON("/actions/runs/"+parts[0], &plan); err != nil || parseErr != nil ||
			plan.Path != ".github/workflows/"+i.workflow || !strings.HasPrefix(plan.Title, i.planPrefix) ||
			plan.Event != "workflow_dispatch" || plan.Status != "completed" || plan.Conclusion != "success" ||
			plan.Attempt != attempt || !matches(`[a-f0-9]{40}`, plan.SHA) {
			return stop(65, "The selected plan ID is not a successful matching workflow attempt.")
		}
		if plan.SHA != sha {
			return stop(65, "The selected plan commit is no longer the local master commit; create a fresh plan.")
		}
	}
	remote, err := read("gh", "api", api+"/commits/master", "--jq", ".sha")
	if err != nil || remote != sha {
		return stop(65, "Local master does not equal the required remote master commit.")
	}
	if i.pullRequest != "" {
		var pr struct {
			State string
			Base  struct {
				Ref, SHA string
				Repo     struct {
					FullName string `json:"full_name"`
				}
			}
			Head struct{ SHA string }
		}
		if err := readJSON("/pulls/"+i.pullRequest, &pr); err != nil || pr.State != "open" ||
			pr.Base.Ref != "master" || pr.Base.Repo.FullName != repository || pr.Base.SHA != sha ||
			!matches(`[a-f0-9]{40}`, pr.Head.SHA) {
			return stop(65, "The pull request is not open against the exact current master commit.")
		}
		i.input("operation", "assess-pull-request")
		i.input("pull_request", i.pullRequest)
		i.input("head_sha", pr.Head.SHA)
		i.input("base_sha", sha)
	}
	// The shared concurrency group can otherwise queue behind a waiting approval.
	active, err := read("gh", "api", api+"/actions/runs?branch=master&per_page=100", "--jq", `
      .workflow_runs[] | select(.status != "completed")
      | select(.path == ".github/workflows/drift.yaml" or .path == ".github/workflows/foundation.yaml"
        or .path == ".github/workflows/recovery.yaml" or .path == ".github/workflows/release.yaml")
      | [.id, .name, .display_title, .status, .html_url] | @tsv`)
	if err != nil {
		return stop(65, "Cannot inspect active infrastructure runs.")
	}
	if active != "" {
		return stop(75, "Another production infrastructure run is active:\n"+active+
			"\nWait for it to finish or resolve it before dispatching another run.")
	}

	_, _ = fmt.Fprintf(stderr, "Dispatching %s from master at %s.\n", i.workflow, sha)
	arguments := append([]string{
		"api", api + "/actions/workflows/" + i.workflow + "/dispatches",
		"--method", "POST", "-H", "X-GitHub-Api-Version: 2026-03-10", "-f", "ref=master",
	}, i.inputs...)
	body, err := read("gh", arguments...)
	var dispatched struct {
		ID  int64  `json:"workflow_run_id"`
		URL string `json:"html_url"`
	}
	// Never retry an uncertain dispatch or print its untrusted response payload.
	if err != nil || json.Unmarshal([]byte(body), &dispatched) != nil ||
		dispatched.ID < 1 || dispatched.ID > 9007199254740991 ||
		dispatched.URL != actionsURL+"/runs/"+strconv.FormatInt(dispatched.ID, 10) {
		return stop(70, "Workflow dispatch could not be confirmed; a run may already exist. Inspect "+actionsURL+" before retrying.")
	}
	id := strconv.FormatInt(dispatched.ID, 10)
	readRun := func() (run, bool) {
		var r run
		err := readJSON("/actions/runs/"+id, &r)
		return r, err == nil && r.ID == dispatched.ID && r.SHA == sha &&
			r.Path == ".github/workflows/"+i.workflow && r.Event == "workflow_dispatch" && r.Branch == "master"
	}
	identityFailure := "The workflow identity could not be verified. Inspect " + dispatched.URL + " before retrying."
	if _, ok := readRun(); !ok {
		return stop(70, identityFailure)
	}
	_, _ = fmt.Fprintln(stderr, "Workflow run:", dispatched.URL)
	if !i.noWait {
		if err := execute(ctx, stderr, "gh", "run", "watch", id, "--repo", repository, "--exit-status"); err != nil {
			return stop(70, "Workflow watch did not succeed. Inspect "+dispatched.URL+" before retrying.")
		}
		r, ok := readRun()
		if !ok {
			return stop(70, identityFailure)
		}
		if r.Status != "completed" || r.Conclusion != "success" || r.Attempt < 1 {
			return stop(70, "The workflow did not finish successfully with the expected identity.")
		}
		if i.attempt {
			id += "-" + strconv.FormatInt(r.Attempt, 10)
		}
	}
	if _, err := fmt.Fprintln(stdout, id); err != nil {
		return stop(70, "Cannot write the workflow result. Inspect "+dispatched.URL+" before retrying.")
	}
	return 0
}
