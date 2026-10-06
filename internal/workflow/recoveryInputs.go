package workflow

import (
	"encoding/json"
	jsonv2 "encoding/json/v2"
	"errors"
	"fmt"
	"io"
	"maps"
	"os"
	"slices"
	"strings"

	"github.com/a-novel/infra/internal/recovery"
)

// RecoveryHost binds a disposable host to independently reviewed recovery inputs.
// The source service owns admission; Project owns only this host's state.
type RecoveryHost struct {
	// Service defaults to JSON Keys for retained recovery records without an explicit service.
	Service            string   `json:"service,omitempty"`
	Project            string   `json:"project"`
	SourceProject      string   `json:"source_project"`
	ProtectedProjects  []string `json:"protected_projects"`
	ManagementProject  string   `json:"management_project"`
	ManagementNumber   string   `json:"management_number"`
	Region             string   `json:"region"`
	Zone               string   `json:"zone"`
	COSImage           string   `json:"cos_image"`
	RestoreImage       string   `json:"restore_image"`
	DiskGiB            int      `json:"disk_gib"`
	SystemID           string   `json:"system_id"`
	Set                string   `json:"set"`
	RepositoryTime     string   `json:"repository_time,omitempty"`
	VerifySQL          bool     `json:"verify_sql,omitempty"`
	ExpectedDataSHA256 string   `json:"expected_data_sha256,omitempty"`
}

// Request is the exact selection shared by the prepared host and its worker.
func (host RecoveryHost) Request() recovery.Request {
	service := host.Service
	if service == "" {
		service = "json-keys"
	}
	return recovery.Request{
		Service: service, SourceProject: host.SourceProject, Project: host.Project,
		ManagementProject: host.ManagementProject, ManagementNumber: host.ManagementNumber,
		SystemID: host.SystemID, Major: 18, Set: host.Set, RepositoryTime: host.RepositoryTime, VerifySQL: host.VerifySQL,
		ExpectedDataSHA256: host.ExpectedDataSHA256,
	}
}

// SourceScope binds recovery admission and receipts to the source's registered private boundary.
// Dedicated service projects retain their historical paths.
func (host RecoveryHost) SourceScope(getenv func(string) string, bucket string) (string, error) {
	service := host.Request().Service
	fields := map[string]string{
		"project_id": host.SourceProject, "service": service, "region": host.Region,
		"management_project_id": host.ManagementProject, "state_bucket": bucket,
	}
	scopes, err := ReleaseScopes(getenv, bucket)
	if err != nil {
		return "", err
	}
	if scopes["workloads/production/private/"+host.SourceProject+"/"+service] == service {
		fields["zone"] = "private"
	}
	data, err := json.Marshal(fields)
	if err != nil {
		return "", err
	}
	return FoundationScope(data, getenv, bucket)
}

// RecoveryScopes lists approved destinations independently of mutation activation.
// Missing registration means no enrolled destinations, not permission to infer them.
func RecoveryScopes(getenv func(string) string, bucket string) (map[string]string, error) {
	services, err := ReleaseScopes(getenv, bucket)
	if err != nil {
		return nil, err
	}
	var registered struct {
		Projects   map[string]string `json:"service_recovery_projects"`
		Management string            `json:"management_project_id"`
		Workload   string            `json:"workload_project_id"`
		Public     string            `json:"public_project_id"`
		PublicAPI  string            `json:"public_api_project_id"`
		Legacy     bool              `json:"recovery_mode"`
	}
	if jsonv2.Unmarshal([]byte(getenv("FOUNDATION_CONFIG")), &registered) != nil {
		return nil, errors.New("invalid recovery registration")
	}
	var fields map[string]json.RawMessage
	if json.Unmarshal([]byte(getenv("FOUNDATION_CONFIG")), &fields) != nil || string(fields["service_recovery_projects"]) == "null" {
		return nil, errors.New("invalid recovery registration")
	}
	scopes := map[string]string{}
	for project, service := range registered.Projects {
		if registered.Legacy || !slices.Contains([]string{"json-keys", "authentication"}, service) || !matches(`a-novel-recovery-[a-z0-9-]{1,13}[a-z0-9]`, project) ||
			project == registered.Management || project == registered.Workload || project == registered.Public || project == registered.PublicAPI || services["services/"+project] != "" ||
			!slices.Contains(slices.Collect(maps.Values(services)), service) {
			return nil, errors.New("invalid recovery destination")
		}
		scopes["services/"+project] = service
	}
	return scopes, nil
}

// RecoveryScope validates private native inputs against the protected registration.
// It is also used by assessment and drift, which never require write activation.
func RecoveryScope(data []byte, getenv func(string) string, bucket string) (RecoveryHost, error) {
	var config struct {
		Bucket   string        `json:"state_bucket"`
		Recovery *RecoveryHost `json:"recovery"`
	}
	invalid := errors.New("native recovery inputs do not match protected registration")
	if jsonv2.Unmarshal(data, &config, jsonv2.RejectUnknownMembers(true)) != nil || config.Recovery == nil {
		return RecoveryHost{}, invalid
	}
	host := *config.Recovery
	scopes, err := RecoveryScopes(getenv, bucket)
	if err != nil || scopes["services/"+host.Project] != host.Request().Service {
		return host, invalid
	}
	if _, err := host.SourceScope(getenv, config.Bucket); err != nil {
		return host, invalid
	}
	if host.Request().Validate() != nil || config.Bucket != bucket || bucket != host.ManagementProject+"-"+host.ManagementNumber+"-tofu-state" {
		return host, invalid
	}
	var registration struct {
		Workload  string            `json:"workload_project_id"`
		Public    string            `json:"public_project_id"`
		PublicAPI string            `json:"public_api_project_id"`
		Projects  map[string]string `json:"service_projects"`
	}
	if jsonv2.Unmarshal([]byte(getenv("FOUNDATION_CONFIG")), &registration) != nil {
		return host, invalid
	}
	protected := []string{host.ManagementProject, registration.Workload}
	for _, project := range []string{registration.Public, registration.PublicAPI} {
		if project != "" {
			protected = append(protected, project)
		}
	}
	for _, project := range registration.Projects {
		protected = append(protected, project)
	}
	for _, project := range protected {
		if !slices.Contains(host.ProtectedProjects, project) {
			return host, invalid
		}
	}
	if slices.Contains(host.ProtectedProjects, host.Project) || host.Region != "europe-west1" ||
		!slices.Contains([]string{"europe-west1-b", "europe-west1-c", "europe-west1-d"}, host.Zone) {
		return host, invalid
	}
	if host.DiskGiB < 10 || host.DiskGiB > 100 ||
		!matches(`projects/cos-cloud/global/images/cos-[0-9]+-[0-9]+-[0-9]+-[0-9]+`, host.COSImage) ||
		!matches(`europe-west1-docker[.]pkg[.]dev/`+host.Project+`/agora-tooling/native-restore@sha256:[a-f0-9]{64}`, host.RestoreImage) {
		return host, invalid
	}
	return host, nil
}

// RecoveryInputs selects native inputs before credentials, or rechecks their backend binding.
func RecoveryInputs(args []string, getenv func(string) string, output, diagnostic io.Writer) int {
	if err := recoveryInputs(args, getenv, output); err != nil {
		_, _ = fmt.Fprintln(diagnostic, "Native recovery input authorization failed; no native mutation is authorized.") // Best effort on a closed stream.
		return 65
	}
	return 0
}

func recoveryInputs(args []string, getenv func(string) string, output io.Writer) error {
	invalid := errors.New("invalid native recovery dispatch")
	if len(args) == 4 && args[0] == "check" {
		data, err := os.ReadFile(args[1])
		if err != nil {
			return err
		}
		host, err := RecoveryScope(data, getenv, args[2])
		if err != nil || args[3] != "services/"+host.Project {
			return invalid
		}
		return nil
	}
	if len(args) != 3 || args[0] != "prepare" || args[2] == "" || strings.ContainsAny(args[2], "\r\n") {
		return invalid
	}
	command := []string{"recovery", getenv("RECOVERY_OPERATION"), args[1]}
	if getenv("RECOVERY_OPERATION") == "cleanup-native" {
		if !RecoveryCleanupEnabled(getenv) || getenv("RECOVERY_PLAN_ID") != "" || getenv("PREPARATION_GENERATION") != "" {
			return invalid
		}
		command = append(command, getenv("CONFIRM"))
	} else if getenv("RECOVERY_OPERATION") == "restore-native" {
		if !RecoveryExecutionEnabled(getenv) || getenv("RECOVERY_PLAN_ID") != "" {
			return invalid
		}
		command = append(command, getenv("PREPARATION_GENERATION"), getenv("CONFIRM"))
	} else {
		if !RecoveryEnabled(getenv) || !slices.Contains([]string{"plan-native", "apply-native"}, getenv("RECOVERY_OPERATION")) ||
			getenv("PREPARATION_GENERATION") != "" || getenv("CONFIRM") != "" {
			return invalid
		}
		if plan := getenv("RECOVERY_PLAN_ID"); plan != "" {
			command = append(command, plan)
		}
	}
	if _, err := parse(command); err != nil {
		return err
	}
	for _, field := range []string{"TARGET_RECEIPT", "JSON_KEYS_ATTEMPT", "AUTHENTICATION_ATTEMPT", "LOST_WRITE_WINDOW"} {
		if getenv(field) != "" {
			return invalid
		}
	}
	var configs map[string]json.RawMessage
	if jsonv2.Unmarshal([]byte(getenv("NATIVE_RECOVERY_CONFIG")), &configs) != nil {
		return invalid
	}
	data := configs[args[1]]
	host, err := RecoveryScope(data, getenv, getenv("STATE_BUCKET"))
	if err != nil || host.Project != args[1] {
		return invalid
	}
	if getenv("RECOVERY_OPERATION") == "restore-native" &&
		(getenv("CONFIRM") != host.Request().Confirmation(getenv("PREPARATION_GENERATION")) || !RecoverySQLAllowed(host.VerifySQL, getenv)) {
		return invalid
	}
	return writeFoundationInputs(args[2], data, output, "services/"+host.Project)
}

// RecoverySQLAllowed requires independent activation for requests that start offline PostgreSQL.
func RecoverySQLAllowed(selected bool, getenv func(string) string) bool {
	return !selected || (getenv("NATIVE_RECOVERY_SQL_ENABLED") == "true" && recoveryWorkflow(getenv))
}

// RecoveryEnabled confines host preparation to the separately activated protected workflow.
func RecoveryEnabled(getenv func(string) string) bool {
	return getenv("NATIVE_RECOVERY_PREPARATION_ENABLED") == "true" && recoveryWorkflow(getenv)
}

// RecoveryExecutionEnabled is independent of host preparation and remains off by default.
func RecoveryExecutionEnabled(getenv func(string) string) bool {
	return getenv("NATIVE_RECOVERY_EXECUTION_ENABLED") == "true" && recoveryWorkflow(getenv)
}

// RecoveryCleanupEnabled is independent of preparation and restoration activation.
func RecoveryCleanupEnabled(getenv func(string) string) bool {
	return getenv("NATIVE_RECOVERY_CLEANUP_ENABLED") == "true" && recoveryWorkflow(getenv)
}

func recoveryWorkflow(getenv func(string) string) bool {
	return getenv("GITHUB_EVENT_NAME") == "workflow_dispatch" &&
		getenv("GITHUB_WORKFLOW_REF") == "a-novel/infra/.github/workflows/recovery.yaml@refs/heads/master"
}
