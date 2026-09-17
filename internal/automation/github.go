package automation

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"regexp"
)

const (
	mainPath      = ".github/workflows/main.yaml"
	driftPath     = ".github/workflows/drift.yaml"
	manifestPath  = "deploy/production/images.yaml"
	deletionLabel = "allow-resource-deletion"
	maxResponse   = 16 << 20
)

var (
	shaPattern        = regexp.MustCompile(`^[a-f0-9]{40}$`)
	repositoryPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$`)
)

type repository struct {
	FullName string `json:"full_name"`
}
type branch struct {
	Ref, SHA string
	Repo     repository
}
type pull struct {
	Number       int64
	State        string
	Draft        *bool
	ChangedFiles int `json:"changed_files"`
	User         struct{ Login, Type string }
	Base, Head   branch
}
type run struct {
	ID                              int64
	WorkflowID                      int64 `json:"workflow_id"`
	Attempt                         int64 `json:"run_attempt"`
	Path, Event, Status, Conclusion string
	HeadSHA                         string `json:"head_sha"`
	HeadBranch                      string `json:"head_branch"`
	Title                           string `json:"display_title"`
	UpdatedAt                       string `json:"updated_at"`
	Repository                      repository
	HeadRepository                  repository `json:"head_repository"`
}
type job struct {
	ID                       int64
	RunID                    int64 `json:"run_id"`
	Attempt                  int64 `json:"run_attempt"`
	Name, Status, Conclusion string
	StartedAt                string `json:"started_at"`
}
type event struct {
	Action      string
	Repository  repository
	WorkflowRun run  `json:"workflow_run"`
	PullRequest pull `json:"pull_request"`
	Label       struct{ Name string }
}
type workflow struct {
	ID   int64
	Path string
}
type target struct {
	Number     int64
	Head, Base string
}

func (t target) valid() bool {
	return positiveID(t.Number) && shaPattern.MatchString(t.Head) && shaPattern.MatchString(t.Base)
}

func (t target) title() string {
	return fmt.Sprintf("resource-deletion assessment PR #%d %s onto %s", t.Number, t.Head, t.Base)
}

func (t target) current(p pull, repo string) bool {
	return p.Number == t.Number && p.State == "open" && p.Base.Ref == "master" &&
		p.Base.Repo.FullName == repo && p.Base.SHA == t.Base && p.Head.SHA == t.Head
}
func positiveID(id int64) bool { return id > 0 && id <= 9007199254740991 }
func (r run) trusted(repo string, w workflow) bool {
	return positiveID(r.ID) && positiveID(w.ID) && r.WorkflowID == w.ID && r.Path == w.Path &&
		r.Repository.FullName == repo && r.HeadRepository.FullName == repo && r.Status == "completed" && positiveID(r.Attempt)
}

type client struct {
	repo    string
	execute func(context.Context, io.Writer, string, ...string) error
}

// limitedOutput bounds metadata buffering even when a child produces invalid JSON.
type limitedOutput struct{ buffer bytes.Buffer }

func (b *limitedOutput) Bytes() []byte  { return b.buffer.Bytes() }
func (b *limitedOutput) String() string { return b.buffer.String() }

func (b *limitedOutput) Write(p []byte) (int, error) {
	if b.buffer.Len()+len(p) > maxResponse {
		return 0, errors.New("metadata response exceeds the size limit")
	}
	return b.buffer.Write(p)
}

func (c client) request(ctx context.Context, path, method string, out any, options ...string) error {
	args := append([]string{"api", "repos/" + c.repo + path, "--method", method}, options...)
	var body limitedOutput
	if err := c.execute(ctx, &body, "gh", args...); err != nil {
		// Child diagnostics may contain response payloads or credentials.
		return fmt.Errorf("GitHub %s request failed; inspect Actions before retrying any uncertain mutation", method)
	}
	if out != nil && (bytes.Equal(bytes.TrimSpace(body.Bytes()), []byte("null")) || json.Unmarshal(body.Bytes(), out) != nil) {
		return errors.New("GitHub returned invalid metadata")
	}
	return nil
}

func fetch[T any](ctx context.Context, c client, path string) (T, error) {
	var value T
	err := c.request(ctx, path, "GET", &value)
	return value, err
}

func list[T any](ctx context.Context, c client, path, key string) ([]T, error) {
	var pages []json.RawMessage
	if err := c.request(ctx, path, "GET", &pages, "--paginate", "--slurp"); err != nil {
		return nil, err
	}
	var values []T
	for _, page := range pages {
		if key != "" {
			var envelope map[string]json.RawMessage
			if err := json.Unmarshal(page, &envelope); err != nil {
				return nil, errors.New("GitHub returned an invalid metadata page")
			}
			page = envelope[key]
		}
		var items []T
		if json.Unmarshal(page, &items) != nil || items == nil {
			return nil, errors.New("GitHub returned an invalid metadata page")
		}
		values = append(values, items...)
	}
	return values, nil
}

func (c client) pull(ctx context.Context, number int64) (pull, error) {
	return fetch[pull](ctx, c, fmt.Sprintf("/pulls/%d", number))
}

func (c client) run(ctx context.Context, id int64) (run, error) {
	return fetch[run](ctx, c, fmt.Sprintf("/actions/runs/%d", id))
}

func (c client) master(ctx context.Context) (string, error) {
	ref, err := fetch[struct{ Object struct{ SHA string } }](ctx, c, "/git/ref/heads/master")
	return ref.Object.SHA, err
}
