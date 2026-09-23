package inspection

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/a-novel/infra/internal/custody"
)

type command func(context.Context, []string, string, ...string) ([]byte, error)

type inspector struct {
	bucket, trusted, candidate, scratch string
	getenv                              func(string) string
	execute                             command
	output                              io.Writer
}

type verdict struct {
	SchemaVersion    int    `json:"schemaVersion"`
	Repository       string `json:"repository"`
	PullRequest      int64  `json:"pullRequest"`
	HeadSHA          string `json:"headSha"`
	BaseSHA          string `json:"baseSha"`
	ApprovalRequired bool   `json:"approvalRequired"`
	FirstLaunch      bool   `json:"firstLaunch"`
}

type failure struct {
	code    int
	message string
}

func (err failure) Error() string { return err.message }

// Run inspects drift or an exact, previously authorized PR candidate. execute
// receives additional environment entries separately from literal arguments and
// must keep child stderr private. This command never applies a plan.
func Run(ctx context.Context, args []string, getenv func(string) string, execute func(context.Context, []string, string, ...string) ([]byte, error), stdout, stderr io.Writer) int {
	err := run(ctx, args, getenv, execute, stdout)
	if err == nil {
		return 0
	}
	fault := failure{70, "Infrastructure inspection failed; private diagnostics were not published."}
	_ = errors.As(err, &fault)
	_, _ = fmt.Fprintln(stderr, fault.message) // Best effort on a closed diagnostic stream.
	return fault.code
}

func run(ctx context.Context, args []string, getenv func(string) string, execute command, output io.Writer) error {
	drift := len(args) == 2 && args[0] == "drift"
	assess := len(args) == 8 && args[0] == "assess"
	if !drift && !assess {
		return failure{64, "Usage: infra inspect drift <bucket> | assess <repository> <pr> <head> <base> <candidate|--image-only> <bucket> <verdict-file>"}
	}
	bucket := args[1]
	if args[0] == "assess" {
		bucket = args[6]
	}
	if !regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{1,220}[a-z0-9]$`).MatchString(bucket) {
		return failure{65, "Invalid inspection bucket."}
	}
	trusted, err := os.Getwd()
	if err != nil {
		return err
	}
	scratch, err := os.MkdirTemp("", "infra-inspection-")
	if err != nil {
		return err
	}
	defer func() { _ = os.RemoveAll(scratch) }() // Best-effort private scratch cleanup.
	i := inspector{bucket, trusted, trusted, scratch, getenv, execute, output}
	if args[0] == "assess" {
		return i.assess(ctx, args[1:])
	}
	for _, root := range []string{"bootstrap", "foundation", "release"} {
		file, code := i.config(ctx, root, "")
		if code == 4 {
			if _, err := fmt.Fprintf(output, "%s has no converged configuration; skipped.\n", root); err != nil {
				return err
			}
			continue
		}
		if code != 0 {
			return failure{70, fmt.Sprintf("Current %s drift inputs could not be proven.", root)}
		}
		if err := i.plan(ctx, "drift", root, file, []string{"TOFU_STATE_SUFFIX="}); err != nil {
			return err
		}
	}
	for _, root := range []string{"service-foundation", "service-release"} {
		if err := i.services(ctx, "drift", root, nil); err != nil {
			return err
		}
	}
	return nil
}

func (i inspector) assessOrDrift(ctx context.Context, mode, root, file string, env []string, result *verdict) error {
	err := i.plan(ctx, mode, root, file, env)
	var fault failure
	if mode == "assess" && errors.As(err, &fault) && fault.code == 3 {
		result.ApprovalRequired = true
		return nil
	}
	return err
}

func (i inspector) config(ctx context.Context, root, scope string) (string, int) {
	file := filepath.Join(i.scratch, strings.ReplaceAll(root+"-"+scope, "/", "-")+".json")
	getenv := func(key string) string {
		if key == "TOFU_STATE_SUFFIX" {
			return scope
		}
		return i.getenv(key)
	}
	code := custody.Run(ctx, []string{"config", "fetch", i.bucket, root, file}, getenv,
		func(ctx context.Context, output io.Writer, name string, args ...string) error {
			data, err := i.execute(ctx, nil, name, args...)
			if err != nil {
				return err
			}
			_, err = output.Write(data)
			return err
		}, io.Discard, io.Discard)
	return file, code
}

func (i inspector) plan(ctx context.Context, mode, root, file string, env []string) error {
	env = append(env, "TOFU_VAR_FILE="+file, "TOFU_REPOSITORY_ROOT="+i.candidate, "ALLOW_RESOURCE_DELETION=false")
	_, err := i.execute(ctx, env, filepath.Join(i.trusted, "ops/tofu-gate.sh"), mode, root, i.bucket)
	if err == nil {
		_, err = fmt.Fprintf(i.output, "%s %s completed.\n", root, mode)
		return err
	}
	var exit interface{ ExitCode() int }
	if errors.As(err, &exit) {
		if mode == "assess" && exit.ExitCode() == 3 {
			return failure{3, "Managed-resource deletion requires approval."}
		}
		if mode == "drift" && exit.ExitCode() == 2 {
			return failure{2, "Infrastructure drift detected; inspect the affected root before mutation."}
		}
	}
	return failure{70, "Read-only plan failed; private diagnostics were not published."}
}
