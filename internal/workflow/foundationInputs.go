package workflow

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
)

// FoundationInputs selects protected foundation configuration before authentication.
// Check revalidates either service root's backend binding before initialization.
// Bind embeds the exact downloaded foundation bytes for job bootstrap.
// These operations never read cloud state or print configuration values.
func FoundationInputs(args []string, getenv func(string) string, stdout, stderr io.Writer) int {
	err := foundationInputs(args, getenv, stdout)
	if err != nil {
		_, _ = fmt.Fprintln(stderr, "Foundation input selection failed; inspect the protected configuration and selected scope.") // Best effort on a closed stream.
		return 65
	}
	return 0
}

// ServiceScopes returns backend scopes and their service names from
// the converged FOUNDATION_CONFIG registration, never from candidate code.
// Older registrations without service_projects describe an empty fleet.
func ServiceScopes(getenv func(string) string, bucket string) (map[string]string, error) {
	var registration map[string]json.RawMessage
	if json.Unmarshal([]byte(getenv("FOUNDATION_CONFIG")), &registration) != nil || registration == nil {
		return nil, errors.New("invalid foundation registration")
	}
	projects := map[string]string{}
	if data, exists := registration["service_projects"]; exists {
		if json.Unmarshal(data, &projects) != nil || projects == nil {
			return nil, errors.New("invalid service registration")
		}
	}
	scopes := make(map[string]string, len(projects))
	for service, project := range projects {
		data, err := json.Marshal(map[string]any{
			"service": service, "project_id": project, "state_bucket": bucket,
			"management_project_id": registration["management_project_id"], "region": registration["region"],
		})
		if err != nil {
			return nil, err
		}
		scope, err := serviceFoundationScope(data, getenv, bucket)
		if err != nil {
			return nil, err
		}
		scopes[scope] = service
	}
	return scopes, nil
}

func foundationInputs(args []string, getenv func(string) string, stdout io.Writer) error {
	invalid := errors.New("invalid protected foundation inputs")
	if len(args) != 4 {
		return invalid
	}
	if args[0] == "bind" {
		return bindFoundation(args[1:], getenv, stdout)
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
	// Direct workflow submissions must satisfy the same contract as the operator command.
	operation := getenv("FOUNDATION_OPERATION")
	if operation != "finish-apply" && (getenv("FOUNDATION_GUARD_GENERATION") != "" || getenv("FOUNDATION_CONFIRM") != "") {
		return invalid
	}
	if operation == "finish-apply" && getenv("FOUNDATION_PLAN_ID") != "" {
		return invalid
	}
	command := []string{"foundation", operation, root}
	if service != "" {
		command = append(command, service)
	}
	if planID := getenv("FOUNDATION_PLAN_ID"); planID != "" {
		command = append(command, planID)
	}
	for _, key := range []string{"FOUNDATION_GUARD_GENERATION", "FOUNDATION_CONFIRM"} {
		if value := getenv(key); value != "" {
			command = append(command, value)
		}
	}
	if _, err := parse(command); err != nil {
		return err
	}
	if operation == "finish-apply" {
		project, err := FinishApplyProject(command[2:], getenv)
		if err != nil {
			return err
		}
		_, err = fmt.Fprintln(stdout, "project="+project)
		return err
	}
	data := []byte(getenv("FOUNDATION_CONFIG"))
	suffix, foundationURI := "", ""
	switch root {
	case "bootstrap", "foundation":
		if service != "" {
			return invalid
		}
		if root == "bootstrap" {
			data = []byte(getenv("BOOTSTRAP_CONFIG"))
		}
	case "service-foundation", "service-release":
		configKey, enabledKey := "SERVICE_FOUNDATION_CONFIG", "SERVICE_FOUNDATIONS_ENABLED"
		if root == "service-release" {
			configKey, enabledKey = "SERVICE_JOB_BOOTSTRAP_CONFIG", "SERVICE_JOB_BOOTSTRAP_ENABLED"
		}
		if operation == "promote-images" {
			enabledKey = "SERVICE_IMAGE_PROMOTION_ENABLED"
		}
		if getenv(enabledKey) != "true" {
			return errors.New("service bootstrap requires separate activation approval")
		}
		var configs map[string]json.RawMessage
		if json.Unmarshal([]byte(getenv(configKey)), &configs) != nil {
			return invalid
		}
		data = configs[service]
		var err error
		suffix, err = serviceFoundationScope(data, getenv, getenv("STATE_BUCKET"))
		if err != nil {
			return err
		}
	default:
		return invalid
	}
	var config map[string]json.RawMessage
	if json.Unmarshal(data, &config) != nil || config == nil {
		return invalid
	}
	if strings.HasPrefix(root, "service-") {
		var declared string
		if json.Unmarshal(config["service"], &declared) != nil || declared != service {
			return invalid
		}
	}
	if root == "service-release" {
		reference, err := foundationSource(config, getenv("STATE_BUCKET"), suffix)
		if err != nil {
			return err
		}
		foundationURI = reference.URI
	}
	if err := writeFoundationInputs(file, data, stdout, suffix); err != nil {
		return err
	}
	if foundationURI != "" {
		_, err := fmt.Fprintln(stdout, "foundation_uri="+foundationURI)
		return err
	}
	return nil
}

// FinishApplyProject authorizes exact-generation recovery from protected registration.
// It needs no current bootstrap inputs or image/secret availability.
func FinishApplyProject(args []string, getenv func(string) string) (string, error) {
	invalid := errors.New("recorded apply recovery requires a confirmed, registered service in the protected workflow")
	if _, err := parse(append([]string{"foundation", "finish-apply"}, args...)); err != nil {
		return "", invalid
	}
	if getenv("SERVICE_OPERATION_RECOVERY_ENABLED") != "true" || getenv("GITHUB_EVENT_NAME") != "workflow_dispatch" ||
		getenv("GITHUB_WORKFLOW_REF") != "a-novel/infra/.github/workflows/foundation.yaml@refs/heads/master" {
		return "", invalid
	}
	scopes, err := ServiceScopes(getenv, getenv("STATE_BUCKET"))
	if err != nil {
		return "", invalid
	}
	for scope, service := range scopes {
		if service == args[1] {
			return strings.TrimPrefix(scope, "services/"), nil
		}
	}
	return "", invalid
}

func writeFoundationInputs(file string, data []byte, stdout io.Writer, suffix string) error {
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
		Project, Management, Region, Bucket, Service string
	}
	var registered struct {
		Projects                     map[string]string
		Management, Workload, Region string
	}
	var fields, registration map[string]json.RawMessage
	if json.Unmarshal(data, &fields) != nil || json.Unmarshal([]byte(getenv("FOUNDATION_CONFIG")), &registration) != nil {
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
	for name, target := range map[string]any{
		"service_projects": &registered.Projects, "management_project_id": &registered.Management,
		"workload_project_id": &registered.Workload, "region": &registered.Region,
	} {
		if json.Unmarshal(registration[name], target) != nil {
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
		!matches(`[a-z][a-z0-9-]{4,28}[a-z0-9]`, selected.Management) || selected.Project == selected.Management {
		return "", invalid
	}
	if !matches(`[a-z][a-z0-9-]{4,28}[a-z0-9]`, registered.Workload) || selected.Project == registered.Workload {
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
