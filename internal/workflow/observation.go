package workflow

import (
	"fmt"
	"io"
)

// ObservationInputs binds an exact rollout to the administrator-approved pilot
// pipeline before authentication. stdout carries only the validated step output.
func ObservationInputs(args []string, getenv func(string) string, stdout, stderr io.Writer) int {
	stop := func(message string) int {
		_, _ = fmt.Fprintln(stderr, message) // Best effort on a closed diagnostic stream.
		return 65
	}
	if getenv("SERVICE_ROLLOUT_OBSERVATION_ENABLED") != "true" {
		return stop("Rollout observation requires separate activation approval.")
	}
	if _, err := parse(append([]string{"drift", "observe-rollout"}, args...)); err != nil {
		return stop("Select json-keys and exact release/rollout IDs for observation.")
	}
	parent := getenv("GCP_JSON_KEYS_ROLLOUT_PARENT")
	if !matches(`projects/[1-9][0-9]*/locations/[a-z]+-[a-z]+[1-9][0-9]*/deliveryPipelines/agora-json-keys-grpc`, parent) {
		return stop("Configure the approved numeric JSON Keys pipeline before observation.")
	}
	if _, err := fmt.Fprintf(stdout, "rollout=%s/releases/%s/rollouts/%s\n", parent, args[1], args[2]); err != nil {
		return stop("Cannot record the authorized rollout identity.")
	}
	return 0
}
