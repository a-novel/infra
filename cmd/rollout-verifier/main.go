// Command rollout-verifier runs Cloud Deploy verification or its private probe.
// It has no deployment, migration, traffic-advance or rollback command.
package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/a-novel/infra/internal/rollout"
)

func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	var err error
	if len(os.Args) == 2 && os.Args[1] == "probe" {
		err = rollout.RunProbe(ctx, os.Getenv("VERIFY_REQUEST"))
	} else if len(os.Args) == 1 {
		var config rollout.Config
		config, err = rollout.FromEnv(os.Getenv)
		if err == nil {
			err = rollout.Verify(ctx, config, os.Stdout)
		}
	} else {
		err = fmt.Errorf("usage: rollout-verifier [probe]")
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
