// Command infra validates operator intent and compiles private deployment inputs.
package main

import (
	"context"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"slices"
	"syscall"
	"time"

	"github.com/a-novel/infra/internal/artifact"
	"github.com/a-novel/infra/internal/automation"
	"github.com/a-novel/infra/internal/custody"
	"github.com/a-novel/infra/internal/database"
	"github.com/a-novel/infra/internal/health"
	"github.com/a-novel/infra/internal/inspection"
	"github.com/a-novel/infra/internal/isolation"
	"github.com/a-novel/infra/internal/operator"
	"github.com/a-novel/infra/internal/release"
	"github.com/a-novel/infra/internal/rollout"
	"github.com/a-novel/infra/internal/submission"
	"github.com/a-novel/infra/internal/workflow"
)

func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	execute := func(ctx context.Context, output io.Writer, name string, args ...string) error {
		command := exec.CommandContext(ctx, name, args...)
		command.Stdout, command.Stderr, command.Stdin = output, os.Stderr, os.Stdin
		if name == "gcloud" {
			command.Env = append(os.Environ(), "CLOUDSDK_CORE_DISABLE_PROMPTS=1")
		}
		return command.Run()
	}
	quiet := func(ctx context.Context, output io.Writer, name string, args ...string) error {
		command := exec.CommandContext(ctx, name, args...)
		command.Env = append(os.Environ(), "CLOUDSDK_CORE_DISABLE_PROMPTS=1")
		data, err := command.Output()
		if err != nil {
			return err
		}
		_, err = output.Write(data)
		return err
	}
	var code int
	if len(os.Args) > 1 && os.Args[1] == "inspect" {
		syscall.Umask(0o077)
		code = inspection.Run(ctx, os.Args[2:], os.Getenv, func(ctx context.Context, env []string, name string, args ...string) ([]byte, error) {
			command := exec.CommandContext(ctx, name, args...)
			command.Env = append(os.Environ(), append(env, "CLOUDSDK_CORE_DISABLE_PROMPTS=1")...)
			// A cancelled plan must not leave a provider process running behind it.
			command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
			command.Cancel = func() error { return syscall.Kill(-command.Process.Pid, syscall.SIGKILL) }
			command.WaitDelay = 5 * time.Second
			return command.Output()
		}, os.Stdout, os.Stderr)
	} else if len(os.Args) > 1 && os.Args[1] == "preflight" {
		code = artifact.Run(ctx, os.Args[2:], quiet, artifact.NewClient(), os.Stdout, os.Stderr)
	} else if len(os.Args) > 1 && os.Args[1] == "promote" {
		code = artifact.Promote(ctx, os.Args[2:], quiet, artifact.NewClient(), os.Stdout, os.Stderr)
	} else if len(os.Args) > 1 && os.Args[1] == "foundation-inputs" {
		code = workflow.FoundationInputs(os.Args[2:], os.Getenv, os.Stdout, os.Stderr)
	} else if len(os.Args) > 1 && os.Args[1] == "database-isolation" {
		// Stop the helper's entire local process group before attempting compensation.
		execute := func(ctx context.Context, output io.Writer, name string, args ...string) error {
			command := exec.CommandContext(ctx, name, args...)
			command.Stdout = output
			command.Env = append(os.Environ(), "CLOUDSDK_CORE_DISABLE_PROMPTS=1")
			command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
			command.Cancel = func() error { return syscall.Kill(-command.Process.Pid, syscall.SIGKILL) }
			command.WaitDelay = 5 * time.Second
			return command.Run()
		}
		syscall.Umask(0o077)
		code = isolation.Run(ctx, os.Args[2:], os.Getenv, execute, os.Stdout, os.Stderr)
	} else if len(os.Args) > 1 && os.Args[1] == "database-release" {
		syscall.Umask(0o077)
		code = database.Run(ctx, os.Args[2:], os.Getenv, quiet, os.Stdout, os.Stderr)
	} else if len(os.Args) > 1 && os.Args[1] == "custody" {
		code = custody.Run(ctx, os.Args[2:], os.Getenv, quiet, os.Stdout, os.Stderr)
	} else if len(os.Args) > 1 && os.Args[1] == "observe-rollout" {
		code = rollout.RunObserver(ctx, os.Args[2:], os.Stdout, os.Stderr)
	} else if len(os.Args) > 1 && slices.Contains([]string{"publish-release-source", "submit-release", "reconcile-release", "submit-rollout", "reconcile-rollout"}, os.Args[1]) {
		code = submission.Run(ctx, os.Args[1:], os.Stdout, os.Stderr)
	} else if len(os.Args) > 1 && os.Args[1] == "check-health" {
		code = health.Run(ctx, os.Args[2:], quiet, nil, os.Stdout, os.Stderr)
	} else if len(os.Args) > 1 && (os.Args[1] == "assess-images" || os.Args[1] == "refresh-deletion-gates") {
		code = automation.Run(ctx, os.Args[1:], os.Getenv, quiet, os.Stdout, os.Stderr)
	} else if len(os.Args) > 1 && (os.Args[1] == "database" || os.Args[1] == "verify-env") {
		syscall.Umask(0o077)
		code = operator.Run(ctx, os.Args[1:], os.Getenv, execute, os.Stdout, os.Stderr)
	} else if len(os.Args) > 1 && os.Args[1] == "foundation-setup" {
		code = operator.Foundation(ctx, os.Args[2:], os.Getenv, func(ctx context.Context, input io.Reader, name string, args ...string) ([]byte, error) {
			command := exec.CommandContext(ctx, name, args...)
			command.Stdin = input
			command.Env = append(os.Environ(), "CLOUDSDK_CORE_DISABLE_PROMPTS=1")
			return command.Output()
		}, os.Stdout, os.Stderr)
	} else if len(os.Args) > 1 && (os.Args[1] == "compile-release" || os.Args[1] == "compile-recovery" || os.Args[1] == "validate-images" || os.Args[1] == "receipt") {
		syscall.Umask(0o077)
		code = release.Run(os.Args[1:], os.Getenv, os.Stdout, os.Stderr)
	} else {
		code = workflow.Run(ctx, os.Args[1:], execute, os.Stdout, os.Stderr)
	}
	cancel()
	os.Exit(code)
}
