package workflow

import (
	"encoding/json"
	"errors"
	"slices"
)

// ReleaseScopes inventories registered release folders, including shared production
// boundaries. Registration alone does not authorize runtime state or deployment.
func ReleaseScopes(getenv func(string) string, bucket string) (map[string]string, error) {
	scopes, err := ServiceScopes(getenv, bucket)
	if err != nil {
		return nil, err
	}
	invalid := errors.New("shared release boundaries do not match protected registration")
	var registration map[string]json.RawMessage
	if json.Unmarshal([]byte(getenv("FOUNDATION_CONFIG")), &registration) != nil {
		return nil, invalid
	}
	zones := map[string][]string{}
	if data, exists := registration["service_release_zones"]; exists {
		if json.Unmarshal(data, &zones) != nil || zones == nil {
			return nil, invalid
		}
	}
	if len(zones) == 0 {
		return scopes, nil
	}
	if len(scopes) != 0 {
		return nil, invalid
	}
	var management, private, public, publicAPI, region string
	for key, target := range map[string]*string{
		"management_project_id": &management, "workload_project_id": &private, "region": &region,
	} {
		if json.Unmarshal(registration[key], target) != nil {
			return nil, invalid
		}
	}
	if !matches(`[a-z][a-z0-9-]{4,28}[a-z0-9]`, management) || management != getenv("MANAGEMENT_PROJECT_ID") ||
		!matches(management+`-[1-9][0-9]*-tofu-state`, bucket) ||
		!matches(`[a-z][a-z0-9-]{4,28}[a-z0-9]`, private) || private == management ||
		!matches(`[a-z]+-[a-z]+[1-9][0-9]*`, region) {
		return nil, invalid
	}
	for key, target := range map[string]*string{"public_project_id": &public, "public_api_project_id": &publicAPI} {
		if data, exists := registration[key]; exists && string(data) != "null" {
			if json.Unmarshal(data, target) != nil || !matches(`[a-z][a-z0-9-]{4,28}[a-z0-9]`, *target) || *target == private || *target == management {
				return nil, invalid
			}
		}
	}
	if publicAPI != "" && publicAPI == public {
		return nil, invalid
	}
	for key, expected := range map[string]bool{"shared_vpc_enabled": true, "recovery_mode": false} {
		var actual bool
		if data, exists := registration[key]; exists {
			if string(data) == "null" || json.Unmarshal(data, &actual) != nil {
				return nil, invalid
			}
		}
		if actual != expected {
			return nil, invalid
		}
	}
	var recoveries map[string]string
	var repositories []string
	for key, target := range map[string]any{"service_recovery_projects": &recoveries, "pgbackrest_repository_services": &repositories} {
		if data, exists := registration[key]; exists {
			if string(data) == "null" || json.Unmarshal(data, target) != nil {
				return nil, invalid
			}
		}
	}
	if len(recoveries) != 0 {
		return nil, invalid
	}
	for _, service := range repositories {
		if service != "json-keys" || !slices.Contains(zones[service], "private") {
			return nil, invalid
		}
	}
	for service, selections := range zones {
		if !slices.Contains([]string{"json-keys", "authentication"}, service) || len(selections) == 0 || len(selections) > 2 {
			return nil, invalid
		}
		for index, zone := range selections {
			if !slices.Contains([]string{"private", "public-api"}, zone) || slices.Contains(selections[:index], zone) {
				return nil, invalid
			}
			project := private
			if zone == "public-api" {
				project = publicAPI
				if project == "" {
					return nil, invalid
				}
			}
			scopes["workloads/production/"+zone+"/"+project+"/"+service] = service
		}
	}
	return scopes, nil
}
