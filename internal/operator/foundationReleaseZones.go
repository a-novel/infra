package operator

import (
	"encoding/json"
	"errors"
	"slices"
)

func (o *foundationOptions) releaseZones(value string) error {
	if json.Unmarshal([]byte(value), &o.serviceReleaseZones) != nil || o.serviceReleaseZones == nil {
		return errors.New("service release zones must be a JSON object")
	}
	if len(o.serviceReleaseZones) > 0 && (!o.sharedVPC || len(o.serviceProjects) != 0) {
		return errors.New("shared release boundaries require shared VPC and no dedicated-service projects")
	}
	for service, zones := range o.serviceReleaseZones {
		if !slices.Contains([]string{"json-keys", "authentication"}, service) || len(zones) == 0 || len(zones) > 2 {
			return errors.New("select private/public-api release zones for JSON Keys or Authentication")
		}
		for index, zone := range zones {
			if !slices.Contains([]string{"private", "public-api"}, zone) || slices.Contains(zones[:index], zone) || zone == "public-api" && o.publicAPIProject == "" {
				return errors.New("release zones must be unique private/public-api selections; public-api requires its project shell and public is reserved for platforms")
			}
		}
	}
	return nil
}
