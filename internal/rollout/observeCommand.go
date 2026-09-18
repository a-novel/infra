package rollout

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"time"

	"google.golang.org/api/option"
)

// RunObserver provides a read-only exit-status boundary for operators and CI.
func RunObserver(ctx context.Context, args []string, stdout, stderr io.Writer, options ...option.ClientOption) int {
	flags := flag.NewFlagSet("observe-rollout", flag.ContinueOnError)
	flags.SetOutput(stderr)
	timeout := flags.Duration("timeout", 10*time.Minute, "maximum observation time, at most 30m")
	summary := flags.String("summary", "", "append payload-free Markdown to this step-summary file")
	if err := flags.Parse(args); err != nil {
		return 64
	}
	if flags.NArg() != 1 {
		_, _ = fmt.Fprintln(stderr, "Usage: infra observe-rollout [--timeout=10m] [--summary=path] <exact-rollout-resource-name>")
		return 64
	}
	output := stdout
	if *summary != "" {
		file, err := os.OpenFile(*summary, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o600)
		if err != nil {
			_, _ = fmt.Fprintln(stderr, "Cannot open the rollout observation summary.")
			return 70
		}
		defer func() { _ = file.Close() }() // Writes are checked by the observer before reporting success.
		output = io.MultiWriter(stdout, file)
	}
	observer := Observer{Name: flags.Arg(0), Timeout: *timeout}
	if err := observer.Wait(ctx, output, options...); err != nil {
		_, _ = fmt.Fprintln(stderr, err)
		return 70
	}
	return 0
}
