package workflow

import (
	"encoding/json"
	"errors"
)

// releaseScope admits registered public APIs without transferring private jobs or databases.
func releaseScope(data []byte, getenv func(string) string, bucket string) (string, error) {
	var fields map[string]json.RawMessage
	if json.Unmarshal(data, &fields) != nil {
		return "", errors.New("invalid release inputs")
	}
	if zone, exists := fields["zone"]; !exists || string(zone) == "null" {
		return ServiceScope(data, getenv, bucket)
	}
	invalid := errors.New("shared release requires a registered public API and no jobs")
	var zone, private, registeredPrivate string
	var registration map[string]json.RawMessage
	var images map[string]string
	if json.Unmarshal(fields["zone"], &zone) != nil || zone != "public-api" ||
		fields["api"] == nil || string(fields["api"]) == "null" ||
		json.Unmarshal(fields["images"], &images) != nil || images == nil || len(images) != 0 ||
		json.Unmarshal(fields["private_project_id"], &private) != nil ||
		json.Unmarshal([]byte(getenv("FOUNDATION_CONFIG")), &registration) != nil ||
		json.Unmarshal(registration["workload_project_id"], &registeredPrivate) != nil || private != registeredPrivate {
		return "", invalid
	}
	return FoundationScope(data, getenv, bucket)
}
