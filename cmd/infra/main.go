// Command infra dispatches a protected operation from the current infra checkout.
package main

import (
	"context"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"syscall"

	"github.com/a-novel/infra/internal/workflow"
)

func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	code := workflow.Run(ctx, os.Args[1:], func(ctx context.Context, output io.Writer, name string, args ...string) error {
		command := exec.CommandContext(ctx, name, args...)
		command.Stdout, command.Stderr, command.Stdin = output, os.Stderr, os.Stdin
		return command.Run()
	}, os.Stdout, os.Stderr)
	cancel()
	os.Exit(code)
}
