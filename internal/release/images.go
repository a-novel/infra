package release

import (
	"errors"
	"fmt"
	"reflect"
	"strings"
)

var families = []struct {
	service, prefix, endpoint string
	slots                     []string
}{
	{"json_keys", "jsonKeys", "grpc", []string{"database", "grpc", "jobs/migrations", "jobs/rotatekeys"}},
	{"authentication", "authentication", "rest", []string{"database", "jobs/init", "jobs/migrations", "rest"}},
}

func component(service string) string { return "service-" + strings.ReplaceAll(service, "_", "-") }

func imageKey(slot string) string {
	return strings.ReplaceAll(strings.TrimPrefix(slot, "jobs/"), "rotatekeys", "rotate_keys")
}

func familyVersions(manifest object) error {
	for _, family := range families {
		definition := obj(manifest, "components", component(family.service))
		if definition["enabled"] != true {
			return errors.New("both components must be enabled for a production release")
		}
		var version string
		for _, slot := range family.slots {
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
		count := 0
		for _, slot := range family.slots {
			oldImage, newImage := obj(before, "images", slot), obj(after, "images", slot)
			if !reflect.DeepEqual(oldImage, newImage) {
				count++
			}
			if oldImage["tag"] == newImage["tag"] && oldImage["digest"] != newImage["digest"] {
				return nil, fmt.Errorf("%s/%s mutates an existing release tag", name, slot)
			}
		}
		if count == 0 && before["enabled"] == after["enabled"] {
			continue
		}
		if count != len(family.slots) {
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

func registry(config object) string {
	return str(config, "region") + "-docker.pkg.dev/" + str(config, "workload_project_id") + "/agora-production/"
}

func promoted(config, image object) string {
	return registry(config) + strings.TrimPrefix(str(image, "repository"), "ghcr.io/a-novel/") + "@" + str(image, "digest")
}

func normalizedImages(config, manifest object) []any {
	images := []any{}
	for _, family := range families {
		for _, slot := range family.slots {
			image := obj(manifest, "components", component(family.service), "images", slot)
			item := clone(image)
			item["component"], item["slot"] = component(family.service), slot
			item["source"] = str(image, "repository") + ":" + str(image, "tag")
			item["sourceDigest"] = str(image, "repository") + "@" + str(image, "digest")
			item["promoted"] = promoted(config, image)
			item["promotedTag"] = strings.Replace(str(item, "promoted"), "@"+str(image, "digest"), ":"+str(image, "tag"), 1)
			images = append(images, item)
		}
	}
	return images
}

func verifyReceiptManifest(config, manifest, receipt object) error {
	// A legacy rollback receipt can name a failed commit. Verify its entire inventory.
	for _, family := range families {
		for _, slot := range family.slots {
			expected := at(receipt, "activeTfvars", "application_release", family.service, "images", imageKey(slot))
			if slot == "database" {
				expected = at(receipt, "database", family.prefix+"Image")
			}
			image := obj(manifest, "components", component(family.service), "images", slot)
			if expected != promoted(config, image) {
				return errors.New("prior image manifest does not match all eight receipt-owned images")
			}
		}
	}
	return nil
}

func runtimeAccounts(project string) object {
	accounts := object{}
	for _, name := range []string{"authentication", "backup", "json-keys", "restore", "scheduler-invoker"} {
		accounts[strings.ReplaceAll(name, "-", "_")] = "agora-" + name + "@" + project + ".iam.gserviceaccount.com"
	}
	return accounts
}

func secretVersions(application, database object) []any {
	if application == nil {
		return []any{}
	}
	return []any{
		[]any{"production-authentication-postgres-password", at(application, "authentication", "secrets", "postgres_password_version")},
		[]any{"production-authentication-postgres-backup-password", database["authenticationBackupPasswordVersion"]},
		[]any{"production-authentication-smtp-sender-password", at(application, "authentication", "secrets", "smtp_password_version")},
		[]any{"production-authentication-super-admin-password", at(application, "authentication", "secrets", "super_admin_password_version")},
		[]any{"production-json-keys-app-master-key", at(application, "json_keys", "secrets", "app_master_key_version")},
		[]any{"production-json-keys-postgres-password", at(application, "json_keys", "secrets", "postgres_password_version")},
		[]any{"production-json-keys-postgres-backup-password", database["jsonKeysBackupPasswordVersion"]},
	}
}
