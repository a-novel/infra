package automation

import (
	"cmp"
	"context"
	"errors"
	"fmt"
	"regexp"
	"slices"
	"strconv"
	"time"
)

var (
	timestampPattern  = regexp.MustCompile(`^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z$`)
	assessmentPattern = regexp.MustCompile(`^resource-deletion assessment PR #([1-9][0-9]*) ([a-f0-9]{40}) onto ([a-f0-9]{40})$`)
)

func timestamp(value string) (time.Time, error) {
	parsed, err := time.Parse(time.RFC3339Nano, value)
	if err != nil || !timestampPattern.MatchString(value) {
		return time.Time{}, errors.New("GitHub returned an invalid event timestamp")
	}
	return parsed, nil
}

func assessmentTarget(r run) target {
	match := assessmentPattern.FindStringSubmatch(r.Title)
	if r.Path != driftPath || r.Event != "workflow_dispatch" || r.HeadBranch != "master" || r.Status != "completed" || len(match) != 4 || r.HeadSHA != match[3] {
		return target{}
	}
	number, _ := strconv.ParseInt(match[1], 10, 64)
	t := target{Number: number, Head: match[2], Base: match[3]}
	if !t.valid() {
		return target{}
	}
	return t
}

func (c client) refreshTarget(ctx context.Context, eventName string, e event) (target, error) {
	if eventName == "pull_request_target" {
		if !slices.Contains([]string{"labeled", "unlabeled"}, e.Action) || e.Label.Name != deletionLabel {
			return target{}, nil
		}
		return target{Number: e.PullRequest.Number, Head: e.PullRequest.Head.SHA, Base: e.PullRequest.Base.SHA}, nil
	}
	if eventName != "workflow_run" || e.Action != "completed" || !positiveID(e.WorkflowRun.ID) {
		return target{}, nil
	}
	r, err := c.run(ctx, e.WorkflowRun.ID)
	if err != nil || r.Repository.FullName != c.repo || r.Status != "completed" {
		return target{}, err
	}
	if t := assessmentTarget(r); t.valid() {
		return t, nil
	}
	if r.Path != mainPath || !slices.Contains([]string{"push", "pull_request"}, r.Event) || r.HeadBranch == "master" || !shaPattern.MatchString(r.HeadSHA) {
		return target{}, nil
	}
	pulls, err := list[pull](ctx, c, "/commits/"+r.HeadSHA+"/pulls?per_page=100", "")
	if err != nil {
		return target{}, err
	}
	var matches []target
	for _, p := range pulls {
		t := target{Number: p.Number, Head: r.HeadSHA, Base: p.Base.SHA}
		if t.current(p, c.repo) {
			matches = append(matches, t)
		}
	}
	if len(matches) != 1 {
		return target{}, nil
	}
	return matches[0], nil
}

func (c client) changedAt(ctx context.Context, t target) (time.Time, error) {
	events, err := list[struct {
		Event     string
		Label     struct{ Name string }
		CreatedAt string `json:"created_at"`
	}](ctx, c, fmt.Sprintf("/issues/%d/events?per_page=100", t.Number), "")
	if err != nil {
		return time.Time{}, err
	}
	changed := time.Unix(0, 0)
	for _, e := range events {
		if !slices.Contains([]string{"labeled", "unlabeled"}, e.Event) || e.Label.Name != deletionLabel {
			continue
		}
		at, err := timestamp(e.CreatedAt)
		if err != nil {
			return time.Time{}, err
		}
		if at.After(changed) {
			changed = at
		}
	}
	runs, err := list[run](ctx, c, "/actions/workflows/drift.yaml/runs?branch=master&event=workflow_dispatch&head_sha="+t.Base+"&per_page=100", "workflow_runs")
	if err != nil {
		return time.Time{}, err
	}
	var latest run
	for _, r := range runs {
		if r.Title == t.title() && r.ID > latest.ID {
			latest = r
		}
	}
	if assessmentTarget(latest).valid() {
		at, err := timestamp(latest.UpdatedAt)
		if err != nil {
			return time.Time{}, err
		}
		if at.After(changed) {
			changed = at
		}
	}
	return changed, nil
}

func (c client) refreshGates(ctx context.Context, eventName string, e event, trustedMain string) ([]string, error) {
	if e.Repository.FullName != c.repo || !shaPattern.MatchString(trustedMain) {
		return nil, errors.New("invalid refresh repository or trusted workflow")
	}
	t, err := c.refreshTarget(ctx, eventName, e)
	if err != nil || !t.valid() {
		return nil, err
	}
	p, err := c.pull(ctx, t.Number)
	if err != nil || !t.current(p, c.repo) || p.Head.Ref == "" || p.Head.Repo.FullName == "" {
		return nil, err
	}
	changed, err := c.changedAt(ctx, t)
	if err != nil || changed.Equal(time.Unix(0, 0)) {
		return nil, err
	}
	w, err := fetch[workflow](ctx, c, "/actions/workflows/main.yaml")
	if err != nil {
		return nil, err
	}
	candidate, err := fetch[blob](ctx, c, "/contents/"+mainPath+"?ref="+t.Head)
	if err != nil {
		return nil, err
	}
	// GitHub reruns dependent jobs too, so the entire CI workflow must be reviewed.
	if w.Path != mainPath || !positiveID(w.ID) || candidate.SHA != trustedMain {
		return nil, errors.New("the candidate CI workflow differs from trusted master; review and refresh it manually")
	}
	runs, err := list[run](ctx, c, "/actions/workflows/main.yaml/runs?head_sha="+t.Head+"&per_page=100", "workflow_runs")
	if err != nil {
		return nil, err
	}
	slices.SortFunc(runs, func(a, b run) int { return cmp.Compare(b.ID, a.ID) })
	selected := make(map[string]bool)
	var refreshed []string
	for _, r := range runs {
		if selected[r.Event] || r.Path != mainPath || r.WorkflowID != w.ID || r.Repository.FullName != c.repo || r.HeadSHA != t.Head || r.HeadBranch != p.Head.Ref || r.HeadRepository.FullName != p.Head.Repo.FullName || !slices.Contains([]string{"push", "pull_request"}, r.Event) || r.HeadBranch == "master" {
			continue
		}
		selected[r.Event] = true
		if !positiveID(r.ID) {
			return nil, errors.New("invalid CI run ID")
		}
		live, err := c.run(ctx, r.ID)
		if err != nil {
			return nil, err
		}
		if live.Status != "completed" || live.HeadSHA != t.Head || live.WorkflowID != w.ID || live.Path != mainPath || !positiveID(live.Attempt) {
			continue
		}
		jobs, err := list[job](ctx, c, fmt.Sprintf("/actions/runs/%d/attempts/%d/jobs?per_page=100", live.ID, live.Attempt), "jobs")
		if err != nil {
			return nil, err
		}
		var gates []job
		for _, j := range jobs {
			if j.Name == "resource-deletion-gate" {
				gates = append(gates, j)
			}
		}
		if len(gates) != 1 || gates[0].Status != "completed" || gates[0].StartedAt == "" {
			continue
		}
		gate := gates[0]
		started, err := timestamp(gate.StartedAt)
		if err != nil {
			return nil, err
		}
		if started.After(changed) {
			continue
		}
		if !positiveID(gate.ID) || gate.RunID != live.ID || gate.Attempt != live.Attempt {
			return nil, errors.New("the gate job does not belong to the selected run attempt")
		}
		current, err := c.pull(ctx, t.Number)
		if err != nil || !t.current(current, c.repo) {
			return refreshed, err
		}
		if err := c.request(ctx, fmt.Sprintf("/actions/jobs/%d/rerun", gate.ID), "POST", nil); err != nil {
			// Concurrent notifications may already have advanced this exact attempt.
			after, readErr := c.run(ctx, live.ID)
			if readErr != nil {
				return nil, readErr
			}
			if after.Status == "completed" && after.Attempt == live.Attempt {
				return nil, err
			}
			continue
		}
		refreshed = append(refreshed, fmt.Sprintf("Requested deletion-gate refresh: run %d, job %d.", live.ID, gate.ID))
	}
	return refreshed, nil
}
