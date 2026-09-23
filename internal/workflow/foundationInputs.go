package workflow

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
)

// FoundationInputs selects protected configuration before authentication. Check
// revalidates the service/backend binding before each OpenTofu initialization.
// Neither operation reads cloud state or prints configuration values.
func FoundationInputs(args []string, getenv func(string) string, stdout, stderr io.Writer) int {
	err := foundationInputs(args, getenv, stdout)
	if err != nil {
		_, _ = fmt.Fprintln(stderr, "Foundation input selection failed; inspect the protected configuration and selected scope.") // Best effort on a closed stream.
		return 65
	}
	return 0
}

func foundationInputs(args []string, getenv func(string) string, stdout io.Writer) error {
	invalid := errors.New("invalid protected foundation inputs")
	if len(args) != 4 {
		return invalid
	}
	if args[0] == "check" {
		data, err := os.ReadFile(args[1])
		if err != nil {
			return err
		}
		suffix, err := serviceFoundationScope(data, getenv, args[2])
		if err != nil || suffix != args[3] {
			return invalid
		}
		return nil
	}
	if args[0] != "prepare" || strings.ContainsAny(args[3], "\r\n") || args[3] == "" {
		return invalid
	}
	root, service, file := args[1], args[2], args[3]
	if service == "none" {
		service = ""
	}
	data := []byte(getenv("FOUNDATION_CONFIG"))
	suffix := ""
	switch root {
	case "bootstrap", "foundation":
		if service != "" {
			return invalid
		}
		if root == "bootstrap" {
			data = []byte(getenv("BOOTSTRAP_CONFIG"))
		}
	case "service-foundation":
		if getenv("SERVICE_FOUNDATIONS_ENABLED") != "true" {
			return errors.New("service foundations require separate activation approval")
		}
		var configs map[string]json.RawMessage
		if json.Unmarshal([]byte(getenv("SERVICE_FOUNDATION_CONFIG")), &configs) != nil {
			return invalid
		}
		data = configs[service]
		var err error
		suffix, err = serviceFoundationScope(data, getenv, getenv("STATE_BUCKET"))
		if err != nil {
			return err
		}
		var selected struct{ Service string }
		if json.Unmarshal(data, &selected) != nil || selected.Service != service {
			return invalid
		}
	default:
		return invalid
	}
	var config map[string]json.RawMessage
	if json.Unmarshal(data, &config) != nil || config == nil {
		return invalid
	}
	// A fresh destination prevents stale private inputs or symlink replacement.
	output, err := os.OpenFile(file, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	_, err = output.Write(data)
	if err = errors.Join(err, output.Close()); err != nil {
		return err
	}
	_, err = fmt.Fprintf(stdout, "file=%s\nstate_suffix=%s\n", file, suffix)
	return err
}

func serviceFoundationScope(data []byte, getenv func(string) string, bucket string) (string, error) {
	invalid := errors.New("service foundation coordinates do not match protected registration")
	var selected struct {
		Project    string `json:"project_id"`
		Management string `json:"management_project_id"`
		Region     string `json:"region"`
		Bucket     string `json:"state_bucket"`
		Service    string `json:"service"`
	}
	var registered struct {
		Projects   map[string]string `json:"service_projects"`
		Management string            `json:"management_project_id"`
		Workload   string            `json:"workload_project_id"`
		Region     string            `json:"region"`
	}
	var fields map[string]json.RawMessage
	if json.Unmarshal(data, &fields) != nil || json.Unmarshal([]byte(getenv("FOUNDATION_CONFIG")), &registered) != nil {
		return "", invalid
	}
	// OpenTofu variable names are case-sensitive, unlike JSON struct decoding.
	for name, target := range map[string]*string{
		"project_id": &selected.Project, "management_project_id": &selected.Management,
		"region": &selected.Region, "state_bucket": &selected.Bucket, "service": &selected.Service,
	} {
		if json.Unmarshal(fields[name], target) != nil {
			return "", invalid
		}
	}
	if selected.Service != "json-keys" && selected.Service != "authentication" {
		return "", invalid
	}
	if !matches(`[a-z][a-z0-9-]{4,28}[a-z0-9]`, selected.Project) || registered.Projects[selected.Service] != selected.Project {
		return "", invalid
	}
	if selected.Management != getenv("MANAGEMENT_PROJECT_ID") || selected.Management != registered.Management ||
		!matches(`[a-z][a-z0-9-]{4,28}[a-z0-9]`, selected.Management) || selected.Project == selected.Management || selected.Project == registered.Workload {
		return "", invalid
	}
	if selected.Region != registered.Region || !matches(`[a-z]+-[a-z]+[1-9][0-9]*`, selected.Region) ||
		selected.Bucket != bucket || !matches(selected.Management+`-[1-9][0-9]*-tofu-state`, bucket) {
		return "", invalid
	}
	for service, project := range registered.Projects {
		if service != selected.Service && project == selected.Project {
			return "", invalid
		}
	}
	return "services/" + selected.Project, nil
}
