package inspection

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
)

func (i inspector) assess(ctx context.Context, args []string) error {
	v := verdict{SchemaVersion: 1, Repository: args[0], HeadSHA: args[2], BaseSHA: args[3]}
	for pattern, values := range map[string][]string{
		`^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`: {v.Repository},
		`^[1-9][0-9]*$`:                     {args[1]}, `^[a-f0-9]{40}$`: {v.HeadSHA, v.BaseSHA},
	} {
		for _, value := range values {
			if !regexp.MustCompile(pattern).MatchString(value) {
				return failure{65, "Invalid assessment identity."}
			}
		}
	}
	if json.Unmarshal([]byte(args[1]), &v.PullRequest) != nil {
		return failure{65, "Invalid assessment identity."}
	}
	i.candidate = args[4]
	imageOnly := i.candidate == "--image-only"
	if imageOnly {
		env := []string{"GITHUB_REPOSITORY=" + v.Repository, "PULL_REQUEST=" + args[1], "HEAD_SHA=" + v.HeadSHA, "BASE_SHA=" + v.BaseSHA}
		if _, err := i.execute(ctx, env, "infra", "assess-images", "verify"); err != nil {
			return failure{77, "Image-only assessment authorization failed."}
		}
	} else {
		if !filepath.IsAbs(i.candidate) {
			return failure{65, "The candidate must be an absolute checkout path."}
		}
		for _, check := range []struct{ verb, argument, expected string }{{"rev-parse", "HEAD", v.HeadSHA}, {"status", "--porcelain", ""}} {
			data, err := i.execute(ctx, nil, "git", "-C", i.candidate, check.verb, check.argument)
			if err != nil || strings.TrimSpace(string(data)) != check.expected {
				return failure{65, "The candidate differs from the exact assessed commit."}
			}
		}
	}
	data, err := i.execute(ctx, nil, "gh", "api", "repos/"+v.Repository+"/pulls/"+args[1])
	var pr struct {
		State string
		Head  struct{ SHA string }
		Base  struct {
			Ref, SHA string
			Repo     struct {
				FullName string `json:"full_name"`
			}
		}
	}
	if err != nil || json.Unmarshal(data, &pr) != nil {
		return failure{70, "Could not read the assessment target."}
	}
	for _, pair := range [][2]string{{pr.State, "open"}, {pr.Base.Ref, "master"}, {pr.Base.Repo.FullName, v.Repository}, {pr.Head.SHA, v.HeadSHA}, {pr.Base.SHA, v.BaseSHA}} {
		if pair[0] != pair[1] {
			return failure{77, "The pull request no longer matches the assessed head and base."}
		}
	}
	data, err = i.execute(ctx, nil, "gh", "api", "--paginate", "--slurp", "repos/"+v.Repository+"/pulls/"+args[1]+"/files?per_page=100")
	var pages [][]json.RawMessage
	if err != nil || json.Unmarshal(data, &pages) != nil || pages == nil {
		return failure{70, "Could not inventory the assessed files."}
	}
	entries := []json.RawMessage{}
	for _, page := range pages {
		entries = append(entries, page...)
	}
	data, err = json.Marshal(entries)
	if err != nil {
		return err
	}
	files := filepath.Join(i.scratch, "files.json")
	if err := os.WriteFile(files, data, 0o600); err != nil {
		return err
	}
	data, err = i.execute(ctx, nil, filepath.Join(i.trusted, "ops/resource-deletion-impact.sh"), files)
	var impact struct {
		Roots           []string
		ReleaseRoot     bool `json:"release_root"`
		ReleaseManifest bool `json:"release_manifest"`
	}
	if err != nil || json.Unmarshal(data, &impact) != nil {
		return failure{70, "Could not determine the assessment scope."}
	}
	if imageOnly && (!slices.Equal(impact.Roots, []string{"release"}) || !impact.ReleaseManifest || impact.ReleaseRoot) {
		return failure{77, "An image-only assessment cannot execute a candidate plan."}
	}
	for _, root := range impact.Roots {
		if root == "service-foundation" || root == "service-release" {
			if err := i.services(ctx, "assess", root, &v); err != nil {
				return err
			}
			continue
		}
		file, code := i.config(ctx, root, "")
		if code == 4 && root == "release" {
			v.FirstLaunch, v.ApprovalRequired = true, true
			continue
		}
		if code != 0 {
			return failure{70, "Current assessment inputs could not be proven."}
		}
		if root == "release" {
			data, err := os.ReadFile(file)
			var config map[string]json.RawMessage
			if err != nil || json.Unmarshal(data, &config) != nil {
				return failure{70, "Release inputs could not be read."}
			}
			if len(config["application_release"]) == 0 || bytes.Equal(bytes.TrimSpace(config["application_release"]), []byte("null")) {
				v.FirstLaunch, v.ApprovalRequired = true, true
			}
			if impact.ReleaseManifest && !impact.ReleaseRoot {
				continue
			}
		}
		if err := i.assessOrDrift(ctx, "assess", root, file, []string{"TOFU_STATE_SUFFIX="}, &v); err != nil {
			return err
		}
	}
	data, err = json.Marshal(v)
	if err != nil {
		return err
	}
	if err = os.MkdirAll(filepath.Dir(args[6]), 0o700); err != nil {
		return err
	}
	file, err := os.OpenFile(args[6], os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	_, err = file.Write(data)
	return errors.Join(err, file.Close())
}
