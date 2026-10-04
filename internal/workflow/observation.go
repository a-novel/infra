package workflow

import (
	"fmt"
	"io"
)

// ObservationInputs authorizes an apply-evidence reader before
// authentication. stdout carries only the selected scope for subsequent steps.
func ObservationInputs(args []string, getenv func(string) string, stdout, stderr io.Writer) int {
	stop := func(message string) int {
		_, _ = fmt.Fprintln(stderr, message) // Best effort on a closed diagnostic stream.
		return 65
	}
	intent, err := parse(append([]string{"drift"}, args...))
	if err != nil || !intent.observation {
		return stop("Select a supported read-only operation and its exact scope.")
	}
	if args[0] == "inspect-operation" {
		scopes, err := OperationScopes(getenv, getenv("STATE_BUCKET"))
		if err != nil {
			return stop("Operation inspection requires protected service registration.")
		}
		for scope, service := range scopes {
			if service == args[1] {
				if _, err := fmt.Fprintln(stdout, "project="+scope); err != nil {
					return stop("Cannot record the authorized service identity.")
				}
				return 0
			}
		}
		return stop("The selected service is not registered for inspection.")
	}
	return stop("Select a supported operation inspection.")
}
