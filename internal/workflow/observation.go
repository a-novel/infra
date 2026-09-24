package workflow

import (
	"fmt"
	"io"
	"strings"
)

// ObservationInputs authorizes a rollout or apply-evidence reader before
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
		scopes, err := ServiceScopes(getenv, getenv("STATE_BUCKET"))
		if err != nil {
			return stop("Operation inspection requires protected service registration.")
		}
		for scope, service := range scopes {
			if service == args[1] {
				if _, err := fmt.Fprintln(stdout, "project="+strings.TrimPrefix(scope, "services/")); err != nil {
					return stop("Cannot record the authorized service identity.")
				}
				return 0
			}
		}
		return stop("The selected service is not registered for inspection.")
	}
	if getenv("SERVICE_ROLLOUT_OBSERVATION_ENABLED") != "true" {
		return stop("Rollout observation requires separate activation approval.")
	}
	parent := getenv("GCP_JSON_KEYS_ROLLOUT_PARENT")
	if !matches(`projects/[1-9][0-9]*/locations/[a-z]+-[a-z]+[1-9][0-9]*/deliveryPipelines/agora-json-keys-grpc`, parent) {
		return stop("Configure the approved numeric JSON Keys pipeline before observation.")
	}
	if _, err := fmt.Fprintf(stdout, "rollout=%s/releases/%s/rollouts/%s\n", parent, args[2], args[3]); err != nil {
		return stop("Cannot record the authorized rollout identity.")
	}
	return 0
}
