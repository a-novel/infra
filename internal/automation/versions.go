package automation

import (
	"context"
	"errors"
	"fmt"
	"path"
	"regexp"
	"slices"
	"strings"
)

const openTofuVersionPath = ".opentofu-version"

var (
	releaseLine  = regexp.MustCompile(`^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$`)
	versionValue = regexp.MustCompile(`^(\s*(?:required_version|version|constraints)\s*=\s*")[0-9A-Za-z.,<>=~! +-]*(")$`)
	lockHash     = regexp.MustCompile(`^\s*"(?:h1|zh):[A-Za-z0-9+/=]+",?$`)
)

// versionPath reports whether a version-only update may change the file.
func versionPath(name string) bool {
	return name == openTofuVersionPath || path.Base(name) == "versions.tf" || path.Base(name) == ".terraform.lock.hcl"
}

// versionValuesOnly reports whether next differs from previous only in version values. A provider lock
// file may also replace its hashes, since they follow the locked version.
func versionValuesOnly(name, previous, next string) bool {
	if previous == next || len(next) > 65536 {
		return false
	}
	normalize := func(content string) []string {
		var lines []string
		for _, line := range strings.Split(content, "\n") {
			switch {
			case name == openTofuVersionPath && releaseLine.MatchString(line):
				line = ""
			case path.Base(name) == ".terraform.lock.hcl" && lockHash.MatchString(line):
				continue
			default:
				line = versionValue.ReplaceAllString(line, "${1}${2}")
			}
			lines = append(lines, line)
		}
		return lines
	}
	return slices.Equal(normalize(previous), normalize(next))
}

// verifyVersions reports whether the PR is a current Renovate update that changes only OpenTofu,
// provider, or lock versions and has passed the same CI evidence as an image update. Its assessment
// plans the candidate with the new upstream binaries; Renovate's release-age gate bounds that trust.
func (c client) verifyVersions(ctx context.Context, t target) (bool, error) {
	if !t.valid() {
		return false, errors.New("invalid version-assessment coordinates")
	}
	p, err := c.pull(ctx, t.Number)
	if err != nil || !c.renovateCandidate(p, t) {
		return false, err
	}
	files, err := list[changedFile](ctx, c, fmt.Sprintf("/pulls/%d/files?per_page=100", t.Number), "")
	if err != nil || len(files) == 0 || len(files) != p.ChangedFiles {
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
	trusted, candidate := regularBlob(before, mainPath), regularBlob(after, mainPath)
	if trusted.SHA == "" || candidate.SHA != trusted.SHA {
		return false, nil
	}
	for _, file := range files {
		if !versionPath(file.Filename) || file.Status != "modified" || file.PreviousFilename != "" {
			return false, nil
		}
		previous, next := regularBlob(before, file.Filename), regularBlob(after, file.Filename)
		if previous.SHA == "" || next.SHA == "" {
			return false, nil
		}
		oldContent, err := c.content(ctx, previous)
		if err != nil {
			return false, err
		}
		newContent, err := c.content(ctx, next)
		if err != nil || !versionValuesOnly(file.Filename, oldContent, newContent) {
			return false, err
		}
	}
	return c.validated(ctx, t, p, c.renovateCandidate)
}
