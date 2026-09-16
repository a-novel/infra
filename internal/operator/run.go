package operator

import (
	"context"
	"fmt"
	"io"
	"path/filepath"
	"regexp"
	"strings"
)

// Run checks operator arguments and returns a diagnostic exit code. getenv supplies
// the operator's environment. execute must pass arguments literally, inherit the
// terminal, disable gcloud prompts, and send child diagnostics to stderr.
func Run(ctx context.Context, args []string, getenv func(string) string, execute func(context.Context, io.Writer, string, ...string) error, stdout, stderr io.Writer) int {
	stop := func(code int, message string) int {
		_, _ = fmt.Fprintln(stderr, message) // Best effort when the diagnostic stream has closed.
		return code
	}
	if len(args) == 0 {
		return stop(64, "Usage: infra verify-env [--github] | database <coordinates|inspect|key|ssh|troubleshoot>")
	}
	if args[0] == "verify-env" {
		if len(args) > 2 || len(args) == 2 && args[1] != "--github" {
			return stop(64, "Usage: infra verify-env [--github]")
		}
		projects, err := projectIDs(getenv)
		if err != nil {
			return stop(64, err.Error())
		}
		message := "PASS operator project coordinates"
		if len(args) == 2 {
			if err := verifyPublished(ctx, projects, execute); err != nil {
				return stop(65, err.Error())
			}
			message = "PASS published project coordinates"
		}
		if _, err := fmt.Fprintln(stdout, message); err != nil {
			return stop(70, "Cannot write operator verification.")
		}
		return 0
	}
	usage := "Usage: infra database coordinates | inspect <authentication|json-keys> | key [--key-file <path>] | <ssh|troubleshoot> <authentication|json-keys> [--key-file <path>] [--ttl <duration>]"
	if args[0] != "database" || len(args) < 2 {
		return stop(64, usage)
	}
	command, service, key, ttl := args[1], "", "", "1h"
	if homeDirectory := getenv("HOME"); homeDirectory != "" {
		key = filepath.Join(homeDirectory, ".ssh/a-novel-gcp-ed25519")
	}
	args = args[2:]
	switch command {
	case "inspect", "ssh", "troubleshoot":
		if len(args) == 0 || args[0] != "authentication" && args[0] != "json-keys" {
			return stop(64, usage)
		}
		service, args = args[0], args[1:]
	case "coordinates", "key":
	default:
		return stop(64, usage)
	}
	for len(args) > 0 {
		if len(args) < 2 || command == "coordinates" || command == "inspect" {
			return stop(64, usage)
		}
		switch args[0] {
		case "--key-file":
			key = args[1]
		case "--ttl":
			if command == "key" {
				return stop(64, usage)
			}
			ttl = args[1]
		default:
			return stop(64, usage)
		}
		args = args[2:]
	}
	usesKey := command == "key" || command == "ssh" || command == "troubleshoot"
	if usesKey && (key == "" || strings.ContainsAny(key, "\r\n") || !matches(`[1-9][0-9]*[smhd]`, ttl)) {
		return stop(64, "SSH key path or lifetime is invalid.")
	}
	client := database{execute: execute}
	if command != "key" {
		projects, err := projectIDs(getenv)
		if err != nil {
			return stop(64, err.Error())
		}
		client.project = projects["GCP_WORKLOAD_PROJECT_ID"]
	}
	if usesKey {
		if err := ensureKey(ctx, key, execute, stdout); err != nil {
			return stop(64, err.Error())
		}
		if command == "key" {
			return 0
		}
	}
	var err error
	if command == "coordinates" {
		err = client.coordinates(ctx, stdout)
	} else {
		var host host
		host, err = client.host(ctx, service)
		if err == nil {
			if command == "inspect" {
				err = client.inspect(ctx, host, stdout)
			} else {
				ssh := []string{"compute", "ssh", host.instance, "--zone=" + host.zone, "--ssh-key-file=" + key, "--ssh-key-expire-after=" + ttl, "--tunnel-through-iap"}
				if command == "troubleshoot" {
					ssh = append(ssh, "--troubleshoot")
				}
				err = client.run(ctx, stdout, ssh...)
			}
		}
	}
	if err != nil {
		return stop(70, err.Error())
	}
	return 0
}

func matches(pattern, value string) bool {
	return regexp.MustCompile("^(?:" + pattern + ")$").MatchString(value)
}
