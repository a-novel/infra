package automation

import (
	"context"
	"crypto/sha1" // Git blob identity, not a cryptographic authorization primitive.
	"encoding/base64"
	"errors"
	"fmt"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"unicode/utf8"
)

var tagLine = regexp.MustCompile(`^        tag: v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$`)

type blob struct {
	Path, Mode, Type, SHA, Encoding, Content string
	Size                                     int64
}

func imageValuesOnly(previous, next string) bool {
	before, after := strings.Split(previous, "\n"), strings.Split(next, "\n")
	if previous == next || len(next) > 65536 || len(before) != len(after) {
		return false
	}
	for i, line := range before {
		if line == after[i] || (tagLine.MatchString(line) && tagLine.MatchString(after[i])) {
			continue
		}
		return false
	}
	return true
}

func (c client) tree(ctx context.Context, sha string) ([]blob, error) {
	value, err := fetch[struct {
		Truncated *bool
		Tree      []blob
	}](ctx, c, "/git/trees/"+sha+"?recursive=1")
	if err != nil {
		return nil, err
	}
	if value.Truncated == nil || *value.Truncated || value.Tree == nil {
		return nil, errors.New("the exact commit tree could not be inventoried")
	}
	return value.Tree, nil
}

func regularBlob(entries []blob, path string) blob {
	var found []blob
	for _, entry := range entries {
		if entry.Path == path {
			found = append(found, entry)
		}
	}
	if len(found) == 1 {
		entry := found[0]
		if entry.Type == "blob" && entry.Mode == "100644" && shaPattern.MatchString(entry.SHA) && entry.Size > 0 && entry.Size <= 65536 {
			return entry
		}
	}
	return blob{}
}

func (c client) content(ctx context.Context, entry blob) (string, error) {
	value, err := fetch[blob](ctx, c, "/git/blobs/"+entry.SHA)
	if err != nil {
		return "", err
	}
	data, decodeErr := base64.StdEncoding.DecodeString(value.Content)
	hash := fmt.Sprintf("%x", sha1.Sum(append(fmt.Appendf(nil, "blob %d\x00", len(data)), data...)))
	if decodeErr != nil || value.Encoding != "base64" || value.SHA != entry.SHA || value.Size != entry.Size ||
		int64(len(data)) != entry.Size || hash != entry.SHA || !utf8.Valid(data) {
		return "", errors.New("the exact manifest blob could not be verified")
	}
	return string(data), nil
}

func (c client) imageCandidate(p pull, t target) bool {
	return t.current(p, c.repo) && p.Draft != nil && !*p.Draft && p.Head.Repo.FullName == c.repo &&
		p.ChangedFiles == 1 && p.User.Login == "anovelbot-dependencies[bot]" && p.User.Type == "Bot"
}

func (c client) verifyImages(ctx context.Context, t target) (bool, error) {
	if !t.valid() {
		return false, errors.New("invalid image-assessment coordinates")
	}
	p, err := c.pull(ctx, t.Number)
	if err != nil || !c.imageCandidate(p, t) {
		return false, err
	}
	files, err := list[struct {
		Filename, Status string
		PreviousFilename string `json:"previous_filename"`
	}](ctx, c, fmt.Sprintf("/pulls/%d/files?per_page=100", t.Number), "")
	if err != nil || len(files) != 1 || files[0].Filename != manifestPath || files[0].Status != "modified" || files[0].PreviousFilename != "" {
		return false, err
	}
	before, err := c.tree(ctx, t.Base)
	if err != nil {
		return false, err
	}
	after, err := c.tree(ctx, t.Head)
	if err != nil {
		return false, err
	}
	previous, next := regularBlob(before, manifestPath), regularBlob(after, manifestPath)
	trusted, candidate := regularBlob(before, mainPath), regularBlob(after, mainPath)
	if previous.SHA == "" || next.SHA == "" || trusted.SHA == "" || candidate.SHA != trusted.SHA {
		return false, nil
	}
	oldContent, err := c.content(ctx, previous)
	if err != nil {
		return false, err
	}
	newContent, err := c.content(ctx, next)
	if err != nil || !imageValuesOnly(oldContent, newContent) {
		return false, err
	}
	w, err := fetch[workflow](ctx, c, "/actions/workflows/main.yaml")
	if err != nil || !positiveID(w.ID) || w.Path != mainPath {
		return false, err
	}
	runs, err := list[run](ctx, c, "/actions/workflows/main.yaml/runs?event=pull_request&head_sha="+t.Head+"&per_page=100", "workflow_runs")
	if err != nil {
		return false, err
	}
	var latest int64
	for _, r := range runs {
		if r.Event == "pull_request" && r.HeadSHA == t.Head && r.HeadBranch == p.Head.Ref && r.ID > latest {
			latest = r.ID
		}
	}
	if !positiveID(latest) {
		return false, nil
	}
	r, err := c.run(ctx, latest)
	if err != nil || !r.trusted(c.repo, w) || r.Event != "pull_request" || r.HeadSHA != t.Head || r.HeadBranch != p.Head.Ref {
		return false, err
	}
	jobs, err := list[job](ctx, c, fmt.Sprintf("/actions/runs/%d/jobs?filter=latest&per_page=100", r.ID), "jobs")
	if err != nil {
		return false, err
	}
	for _, required := range []string{"validate-opentofu", "scan-infrastructure", "lint-repository"} {
		var matches []job
		for _, j := range jobs {
			if j.Name == required {
				matches = append(matches, j)
			}
		}
		if len(matches) != 1 {
			return false, nil
		}
		j := matches[0]
		if j.RunID != r.ID || !positiveID(j.Attempt) || j.Attempt > r.Attempt || j.Status != "completed" || j.Conclusion != "success" {
			return false, nil
		}
	}
	// Recheck mutable evidence after all paginated validation reads.
	live, err := c.run(ctx, r.ID)
	if err != nil || live.Status != "completed" || live.Attempt != r.Attempt {
		return false, err
	}
	p, err = c.pull(ctx, t.Number)
	if err != nil || !c.imageCandidate(p, t) {
		return false, err
	}
	master, err := c.master(ctx)
	return master == t.Base, err
}

func (c client) dispatchImages(ctx context.Context, e event, base string) ([]int64, error) {
	if e.Action != "completed" || e.Repository.FullName != c.repo || !positiveID(e.WorkflowRun.ID) || !shaPattern.MatchString(base) {
		return nil, nil
	}
	r, err := c.run(ctx, e.WorkflowRun.ID)
	if err != nil {
		return nil, err
	}
	assessment := r.Path == driftPath && r.Event == "workflow_dispatch" && r.HeadBranch == "master"
	name, path := "main", mainPath
	if assessment {
		name, path = "drift", driftPath
	}
	w, err := fetch[workflow](ctx, c, "/actions/workflows/"+name+".yaml")
	if err != nil || w.Path != path || !r.trusted(c.repo, w) || !shaPattern.MatchString(r.HeadSHA) {
		return nil, err
	}
	if !assessment && (!slices.Contains([]string{"push", "pull_request"}, r.Event) ||
		(r.HeadBranch == "master" && (r.Event != "push" || r.HeadSHA != base || r.Conclusion != "success"))) {
		return nil, nil
	}
	master, err := c.master(ctx)
	if err != nil || master != base {
		return nil, err
	}
	pulls, err := list[pull](ctx, c, "/pulls?state=open&base=master&per_page=100", "")
	if err != nil {
		return nil, err
	}
	assessments, err := list[run](ctx, c, "/actions/workflows/drift.yaml/runs?branch=master&event=workflow_dispatch&per_page=100", "workflow_runs")
	if err != nil {
		return nil, err
	}
	for _, a := range assessments {
		if slices.Contains([]string{"queued", "in_progress", "waiting", "pending", "requested"}, a.Status) {
			return nil, nil
		}
	}
	for _, p := range pulls {
		t := target{Number: p.Number, Head: p.Head.SHA, Base: base}
		if !t.valid() {
			continue
		}
		if slices.ContainsFunc(assessments, func(a run) bool {
			return a.Title == t.title() && a.Path == driftPath && a.HeadSHA == base && a.Event == "workflow_dispatch" && a.HeadBranch == "master"
		}) {
			continue
		}
		ok, err := c.verifyImages(ctx, t)
		if err != nil {
			return nil, err
		}
		if !ok {
			continue
		}
		// One completion advances one request; failed tuples remain for human diagnosis.
		err = c.request(ctx, "/actions/workflows/drift.yaml/dispatches", "POST", nil,
			"-f", "ref=master", "-f", "inputs[operation]=assess-image-update",
			"-f", "inputs[pull_request]="+strconv.FormatInt(t.Number, 10), "-f", "inputs[head_sha]="+t.Head, "-f", "inputs[base_sha]="+base)
		if err != nil {
			return nil, err
		}
		return []int64{t.Number}, nil
	}
	return nil, nil
}
