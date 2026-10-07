package release

import (
	"errors"
	"fmt"
	"reflect"
	"strings"
)

var families = []struct {
	service string
	slots   []string
}{
	{"json_keys", []string{"database", "grpc", "jobs/migrations", "jobs/rotatekeys"}},
	{"authentication", []string{"database", "jobs/init", "jobs/migrations", "rest"}},
}

func component(service string) string { return "service-" + strings.ReplaceAll(service, "_", "-") }

func familyVersions(manifest object, selected ...string) error {
	for _, family := range families {
		if len(selected) != 0 && component(family.service) != "service-"+selected[0] {
			continue
		}
		definition := obj(manifest, "components", component(family.service))
		if definition["enabled"] != true {
			return errors.New("both components must be enabled for a production release")
		}
		var version string
		for _, slot := range family.slots {
			if obj(definition, "images", slot) == nil {
				continue
			}
			tag := str(definition, "images", slot, "tag")
			if version != "" && version != tag {
				return errors.New("component images must use one SemVer release")
			}
			version = tag
		}
	}
	return nil
}

func imageChanges(previous, next object) ([]string, error) {
	changed := []string{}
	firstLaunch := true
	for _, family := range families {
		name := component(family.service)
		before, after := obj(previous, "components", name), obj(next, "components", name)
		firstLaunch = firstLaunch && before["enabled"] != true
		count, total := 0, 0
		for _, slot := range family.slots {
			oldImage, newImage := obj(before, "images", slot), obj(after, "images", slot)
			if oldImage == nil && newImage == nil {
				continue
			}
			total++
			if oldImage["repository"] != newImage["repository"] || oldImage["tag"] != newImage["tag"] {
				count++
				continue
			}
			oldDigest, newDigest := str(oldImage, "digest"), str(newImage, "digest")
			if oldDigest != "" && newDigest != "" && oldDigest != newDigest {
				return nil, fmt.Errorf("%s/%s mutates an existing release tag", name, slot)
			}
		}
		if count == 0 && before["enabled"] == after["enabled"] {
			continue
		}
		if count != total {
			return nil, fmt.Errorf("%s must update its complete image family", name)
		}
		changed = append(changed, family.service)
	}
	if !reflect.DeepEqual(previous["postgresMajor"], next["postgresMajor"]) && len(changed) > 0 {
		return nil, errors.New("a PostgreSQL major change must be reviewed separately")
	}
	if !firstLaunch && len(changed) > 1 {
		return nil, errors.New("service image families must be deployed separately")
	}
	return changed, nil
}
