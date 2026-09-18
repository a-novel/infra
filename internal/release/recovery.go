package release

import (
	"errors"
	"fmt"
	"maps"
	"reflect"
	"regexp"
	"slices"
	"strings"
)

var (
	attemptPattern = regexp.MustCompile(`^[0-9]+-[a-z0-9-]{1,63}-[0-9]+$`)
	projectPattern = regexp.MustCompile(`^[a-z][a-z0-9-]{4,28}[a-z0-9]$`)
)

func remapImages(value any, source, target string) (any, error) {
	switch typed := value.(type) {
	case object:
		for key, item := range typed {
			mapped, err := remapImages(item, source, target)
			if err != nil {
				return nil, err
			}
			typed[key] = mapped
		}
	case []any:
		for index, item := range typed {
			mapped, err := remapImages(item, source, target)
			if err != nil {
				return nil, err
			}
			typed[index] = mapped
		}
	case string:
		if strings.Contains(typed, "-docker.pkg.dev/") && strings.Contains(typed, "@sha256:") {
			if !strings.HasPrefix(typed, source) {
				return nil, errors.New("receipt image is outside its original immutable registry")
			}
			return target + strings.TrimPrefix(typed, source), nil
		}
	}
	return value, nil
}

// CompileRecovery derives a disposable foundation and staged release from a
// receipt. Arguments name foundation config, receipt, outputs (or "-"), replacement
// project, both backup attempts, phase, and private output directory.
func (compiler *Compiler) CompileRecovery(args []string, identity Identity) error {
	if len(args) != 8 {
		return errors.New("invalid recovery compilation arguments")
	}
	target, phase := args[3], args[6]
	if !projectPattern.MatchString(target) || (phase != "foundation" && phase != "release") {
		return errors.New("invalid recovery target or phase")
	}
	config, err := read(args[0], "foundation configuration", false)
	if err != nil {
		return err
	}
	receipt, err := compiler.load(args[1], "receipt")
	if err != nil {
		return err
	}
	source := obj(receipt, "activeTfvars")
	sourceProject, management := str(source, "workload_project_id"), str(source, "management_project_id")
	if obj(receipt, "database") == nil || obj(source, "application_release") == nil || !projectPattern.MatchString(sourceProject) || !projectPattern.MatchString(management) || target == sourceProject || target == management {
		return errors.New("selected receipt is not a recoverable application state")
	}
	for _, key := range []string{"management_project_id", "workload_project_id", "region", "backup_bucket_name"} {
		if !reflect.DeepEqual(config[key], source[key]) {
			return errors.New("recovery foundation configuration does not match the source receipt")
		}
	}
	if projects, exists := config["service_projects"]; exists {
		values, ok := projects.(object)
		if !ok {
			return errors.New("source service projects are invalid")
		}
		for _, value := range values {
			project, ok := value.(string)
			if !ok || !projectPattern.MatchString(project) {
				return errors.New("source service project ID is invalid")
			}
			if project == target {
				return errors.New("recovery target is a configured production service project")
			}
		}
	}
	foundation := clone(config)
	foundation["workload_project_id"], foundation["workload_project_name"], foundation["recovery_mode"] = target, "Agora recovery", true
	foundation["service_projects"] = object{}
	outputs := map[string]any{"foundation.tfvars.json": foundation}
	if phase == "foundation" {
		return writeOutputs(args[7], outputs)
	}
	if err = identity.validate(); err != nil {
		return err
	}
	if !attemptPattern.MatchString(args[4]) || !attemptPattern.MatchString(args[5]) {
		return errors.New("exact recovery attempt is invalid")
	}
	state, err := read(args[2], "recovery foundation outputs", false)
	if err != nil {
		return err
	}
	for _, key := range []string{"workload_project_id", "network", "database_hosts", "cloud_run_invocation_tags"} {
		if at(state, key, "value") == nil {
			return fmt.Errorf("foundation output %s is absent", key)
		}
	}
	if str(state, "workload_project_id", "value") != target {
		return errors.New("recovery state identifies a different replacement project")
	}
	transformed := clone(source)
	transformed["workload_project_id"] = target
	sourceRegistry, targetRegistry := registry(source), registry(transformed)
	if _, err = remapImages(transformed, sourceRegistry, targetRegistry); err != nil {
		return err
	}
	transformed["runtime_service_accounts"] = runtimeAccounts(target)
	transformed["network_id"] = at(state, "network", "value", "network_id")
	transformed["subnet_id"] = at(state, "network", "value", "subnet_id")
	transformed["cloud_run_invocation_tags"] = at(state, "cloud_run_invocation_tags", "value")
	transformed["recovery_mode"], transformed["recovery_source_project_id"] = true, sourceProject
	delete(transformed, "database_private_ip")
	databaseHosts, sourceIPs, databaseImages, passwords, hosts := object{}, object{}, object{}, object{}, object{}
	database := clone(obj(receipt, "database"))
	seed := identity.seed(target)
	application := obj(transformed, "application_release")
	application["rollout"] = object{"candidate_tag": "c-" + seed[24:40], "phase": "active"}
	images := []any{}
	seen := map[string]bool{}
	imageSources := []string{str(database, "authenticationImage"), str(database, "jsonKeysImage")}
	for _, service := range []string{"authentication", "json_keys"} {
		applicationImages := obj(source, "application_release", service, "images")
		for _, key := range slices.Sorted(maps.Keys(applicationImages)) {
			image := applicationImages[key]
			text, ok := image.(string)
			if !ok {
				return errors.New("receipt application image is invalid")
			}
			imageSources = append(imageSources, text)
		}
	}
	for _, image := range imageSources {
		if seen[image] {
			continue
		}
		seen[image] = true
		if !strings.HasPrefix(image, sourceRegistry) || !strings.Contains(image, "@sha256:") {
			return errors.New("receipt image is outside its original immutable registry")
		}
		promoted := targetRegistry + strings.TrimPrefix(image, sourceRegistry)
		name, digest, _ := strings.Cut(promoted, "@")
		images = append(images, object{"source": image, "target": promoted, "digest": digest, "tag": name + ":recovery-" + identity.RunID})
	}
	if len(images) != 8 {
		return errors.New("selected receipt does not contain eight images")
	}
	for _, family := range families {
		service, prefix := family.service, family.prefix
		host := obj(state, "database_hosts", "value", service)
		if host["private_ip"] == nil || at(host, "data_disk", "id") == nil {
			return errors.New("recovery database host is incomplete")
		}
		diskID := fmt.Sprint(at(host, "data_disk", "id"))
		databaseHosts[service] = object{"private_ip": host["private_ip"], "data_disk_id": diskID}
		hosts[service] = object{"privateIp": host["private_ip"], "dataDiskId": diskID, "releaseRevision": identity.Commit}
		sourceIPs[service] = at(source, "database_hosts", service, "private_ip")
		if sourceIPs[service] == nil {
			sourceIPs[service] = source["database_private_ip"]
		}
		databaseImages[service], passwords[service] = database[prefix+"Image"], database[prefix+"PasswordVersion"]
		database[prefix+"Image"] = at(transformed, "database_releases", service, "image")
		app := obj(application, service)
		if app == nil || obj(app, "secrets") == nil {
			return errors.New("receipt application configuration is incomplete")
		}
		suffix := seed[:12]
		if service == "json_keys" {
			suffix = seed[12:24]
		}
		revision := "agora-" + strings.ReplaceAll(service, "_", "-") + "-" + family.endpoint + "-" + suffix
		app["revision"], app["active_revision"] = revision, revision
		obj(app, "secrets")["postgres_password_version"] = passwords[service]
	}
	transformed["database_hosts"], transformed["recovery_source_database_ips"] = databaseHosts, sourceIPs
	transformed["recovery_database_images"], transformed["recovery_database_password_versions"] = databaseImages, passwords
	transformed["recovery_backup_attempts"] = object{"json_keys": args[4], "authentication": args[5]}
	database["hosts"], database["releaseRevision"] = hosts, identity.Commit
	staging := clone(transformed)
	staging["application_release"] = nil
	quotas := object{"cloud_run_cpu_millicpu": 8000, "cloud_run_memory_bytes": 17179869184, "compute_cpu": 4}
	for key, field := range map[string]string{"cloud_run_cpu_millicpu": "cloud_run_cpu_quota_millicpu", "cloud_run_memory_bytes": "cloud_run_memory_quota_bytes", "compute_cpu": "compute_cpu_quota"} {
		if foundation[field] != nil {
			quotas[key] = foundation[field]
		}
	}
	outputs["staging.tfvars.json"], outputs["active.tfvars.json"] = staging, transformed
	outputs["images.json"], outputs["database.json"] = images, database
	outputs["preflight.json"] = object{"schemaVersion": 1, "action": "deploy", "cloud": object{"managementProjectId": management, "workloadProjectId": target, "region": source["region"], "quotaExpectations": quotas, "secretVersions": secretVersions(application, database)}}
	return writeOutputs(args[7], outputs)
}
