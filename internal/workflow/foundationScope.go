package workflow

import (
	"encoding/json"
	"errors"
	"strings"
)

// FoundationScope authorizes prerequisites and stopped repository placement in a registered service/zone state.
func FoundationScope(data []byte, getenv func(string) string, bucket string) (string, error) {
	var fields, registration map[string]json.RawMessage
	if json.Unmarshal(data, &fields) != nil {
		return "", errors.New("invalid foundation inputs")
	}
	if zone, exists := fields["zone"]; !exists || string(zone) == "null" {
		if handoff, exists := fields["database_handoff"]; exists && string(handoff) != "null" {
			return "", errors.New("database handoff requires a shared foundation scope")
		}
		return ServiceScope(data, getenv, bucket)
	}
	invalid := errors.New("shared foundation inputs do not match protected prerequisites")
	scopes, err := ReleaseScopes(getenv, bucket)
	if err != nil || json.Unmarshal([]byte(getenv("FOUNDATION_CONFIG")), &registration) != nil {
		return "", invalid
	}
	var service, zone, project, management, region, selectedBucket, registeredRegion string
	for key, target := range map[string]*string{
		"service": &service, "zone": &zone, "project_id": &project,
		"management_project_id": &management, "region": &region, "state_bucket": &selectedBucket,
	} {
		if json.Unmarshal(fields[key], target) != nil {
			return "", invalid
		}
	}
	scope := "workloads/production/" + zone + "/" + project + "/" + service
	if service == "" || scopes[scope] != service || management != getenv("MANAGEMENT_PROJECT_ID") ||
		selectedBucket != bucket || json.Unmarshal(registration["region"], &registeredRegion) != nil || region != registeredRegion {
		return "", invalid
	}
	for _, key := range []string{"database", "database_runtime", "rollout"} {
		if value, exists := fields[key]; exists && string(value) != "null" {
			return "", invalid
		}
	}
	if value, exists := fields["pgbackrest_repository"]; exists && string(value) != "null" {
		var repository struct {
			Placement   map[string]json.RawMessage `json:"placement"`
			MachineType *string                    `json:"machine_type"`
			Runtime     json.RawMessage            `json:"runtime"`
		}
		if service != "json-keys" || zone != "private" || json.Unmarshal(value, &repository) != nil ||
			len(repository.Placement) == 0 || (repository.MachineType != nil && *repository.MachineType != "e2-micro") ||
			(len(repository.Runtime) != 0 && string(repository.Runtime) != "null") ||
			len(fields["database_handoff"]) == 0 || string(fields["database_handoff"]) == "null" {
			return "", invalid
		}
	}
	if value, exists := fields["manage_job_access"]; exists && string(value) != "false" {
		return "", invalid
	}
	if value, exists := fields["database_handoff"]; exists && string(value) != "null" {
		var handoff struct {
			PrivateProjectID string `json:"private_project_id"`
		}
		var privateProject string
		if json.Unmarshal(value, &handoff) != nil ||
			json.Unmarshal(registration["workload_project_id"], &privateProject) != nil ||
			privateProject == "" || handoff.PrivateProjectID != privateProject {
			return "", invalid
		}
	}
	return scope, nil
}

// OperationScopes keeps one admission key per service across its registered zones.
// Dedicated projects retain their historical key and evidence paths.
func OperationScopes(getenv func(string) string, bucket string) (map[string]string, error) {
	scopes, err := ReleaseScopes(getenv, bucket)
	if err != nil {
		return nil, err
	}
	operations := make(map[string]string, len(scopes))
	for scope, service := range scopes {
		key := strings.TrimPrefix(scope, "services/")
		if strings.HasPrefix(scope, "workloads/") {
			key = "workloads/production/" + service
		}
		operations[key] = service
	}
	return operations, nil
}
