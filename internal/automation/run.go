package automation

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"slices"
	"strconv"
	"strings"
)

// Run handles cloud-blind GitHub gate automation. execute must capture stdout
// without forwarding child stderr or accepting interactive input.
func Run(ctx context.Context, args []string, getenv func(string) string, execute func(context.Context, io.Writer, string, ...string) error, stdout, stderr io.Writer) int {
	mode := strings.Join(args, " ")
	if !slices.Contains([]string{"assess-updates dispatch", "assess-images verify", "assess-versions verify", "refresh-deletion-gates"}, mode) {
		_, _ = fmt.Fprintln(stderr, "Usage: infra assess-updates dispatch | assess-images verify | assess-versions verify | refresh-deletion-gates")
		return 64
	}
	c := client{repo: getenv("GITHUB_REPOSITORY"), execute: execute}
	if !repositoryPattern.MatchString(c.repo) {
		_, _ = fmt.Fprintln(stderr, "Invalid GitHub repository.")
		return 65
	}
	summary, err := c.command(ctx, mode, getenv)
	if err == nil && mode == "refresh-deletion-gates" && getenv("GITHUB_STEP_SUMMARY") != "" {
		file, openErr := os.OpenFile(getenv("GITHUB_STEP_SUMMARY"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
		if openErr != nil {
			err = errors.New("could not open the workflow summary")
		} else {
			_, writeErr := fmt.Fprintln(file, summary)
			closeErr := file.Close()
			if writeErr != nil || closeErr != nil {
				err = errors.New("could not write the workflow summary")
			}
		}
	}
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "::error::%s\n", err)
		return 70
	}
	_, _ = fmt.Fprintln(stdout, summary)
	return 0
}

func (c client) command(ctx context.Context, mode string, getenv func(string) string) (string, error) {
	if mode == "assess-images verify" || mode == "assess-versions verify" {
		number, _ := strconv.ParseInt(getenv("PULL_REQUEST"), 10, 64)
		t := target{Number: number, Head: getenv("HEAD_SHA"), Base: getenv("BASE_SHA")}
		if getenv("GITHUB_REF") != "refs/heads/master" || getenv("GITHUB_SHA") != t.Base {
			return "", errors.New("update assessment must run from the exact master commit")
		}
		verify, kind := c.verifyImages, "image-only"
		if mode == "assess-versions verify" {
			verify, kind = c.verifyVersions, "version-only"
		}
		ok, err := verify(ctx, t)
		if err != nil {
			return "", err
		}
		if !ok {
			return "", fmt.Errorf("the PR is not a current, validated %s Renovate update", kind)
		}
		return fmt.Sprintf("Verified the exact %s Renovate update.", kind), nil
	}
	file, err := os.Open(getenv("GITHUB_EVENT_PATH"))
	if err != nil {
		return "", errors.New("could not read the GitHub event")
	}
	data, readErr := io.ReadAll(io.LimitReader(file, maxResponse+1))
	closeErr := file.Close()
	var e event
	if readErr != nil || closeErr != nil || len(data) > maxResponse || json.Unmarshal(data, &e) != nil {
		return "", errors.New("invalid GitHub event")
	}
	revision := "HEAD"
	if mode == "refresh-deletion-gates" {
		revision += ":" + mainPath
	}
	var out limitedOutput
	if err := c.execute(ctx, &out, "git", "rev-parse", revision); err != nil {
		return "", errors.New("could not resolve the trusted checkout")
	}
	trusted := strings.TrimSpace(out.String())
	if mode == "assess-updates dispatch" {
		if getenv("GITHUB_EVENT_NAME") != "workflow_run" {
			return "", errors.New("update assessment dispatch requires a workflow completion")
		}
		ids, err := c.dispatchUpdates(ctx, e, trusted)
		if err != nil {
			return "", err
		}
		if len(ids) == 0 {
			return "No Renovate update assessment needs requesting.", nil
		}
		return fmt.Sprintf("Requested a Renovate update assessment for PR #%d.", ids[0]), nil
	}
	lines, err := c.refreshGates(ctx, getenv("GITHUB_EVENT_NAME"), e, trusted)
	if err != nil {
		return "", err
	}
	if len(lines) == 0 {
		return "No stale completed deletion gates need refreshing.", nil
	}
	return strings.Join(lines, "\n"), nil
}
