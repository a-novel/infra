// Command infra validates operator intent and compiles private deployment inputs.
package main

import (
	"context"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"syscall"

	"github.com/a-novel/infra/internal/automation"
	"github.com/a-novel/infra/internal/operator"
	"github.com/a-novel/infra/internal/release"
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
	var code int
	if len(os.Args) > 1 && (os.Args[1] == "assess-images" || os.Args[1] == "refresh-deletion-gates") {
		quiet := func(ctx context.Context, output io.Writer, name string, args ...string) error {
			command := exec.CommandContext(ctx, name, args...)
			command.Stdout = output
			return command.Run()
		}
		code = automation.Run(ctx, os.Args[1:], os.Getenv, quiet, os.Stdout, os.Stderr)
	} else if len(os.Args) > 1 && (os.Args[1] == "database" || os.Args[1] == "verify-env") {
		syscall.Umask(0o077)
		code = operator.Run(ctx, os.Args[1:], os.Getenv, execute, os.Stdout, os.Stderr)
	} else if len(os.Args) > 1 && (os.Args[1] == "compile-release" || os.Args[1] == "compile-recovery" || os.Args[1] == "validate-images" || os.Args[1] == "receipt") {
		syscall.Umask(0o077)
		code = release.Run(os.Args[1:], os.Getenv, os.Stdout, os.Stderr)
	} else {
		code = workflow.Run(ctx, os.Args[1:], execute, os.Stdout, os.Stderr)
	}
	cancel()
	os.Exit(code)
}
