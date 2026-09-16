package release

import (
	"errors"
	"net/netip"
	"net/url"
	"os"
	"reflect"
	"regexp"
	"strconv"
	"strings"
)

// Identity names an exact workflow attempt; Nonce distinguishes its immutable revisions.
type Identity struct {
	Commit     string // Commit is the reviewed checkout's full SHA.
	RunID      string // RunID is the decimal GitHub workflow run ID.
	RunAttempt int    // RunAttempt is the positive workflow attempt number.
	Nonce      string // Nonce supplies fresh entropy for release revision names.
}

var (
	commitPattern = regexp.MustCompile(`^[a-f0-9]{40}$`)
	runPattern    = regexp.MustCompile(`^[1-9][0-9]*$`)
	originPattern = regexp.MustCompile(`^https://[a-z0-9][a-z0-9.-]*\.[a-z0-9-]+(?::[0-9]+)?$`)
)

func (identity Identity) validate() error {
	if !commitPattern.MatchString(identity.Commit) || !runPattern.MatchString(identity.RunID) || identity.RunAttempt < 1 {
		return errors.New("release workflow identity is invalid")
	}
	return nil
}

func (identity Identity) seed(suffix string) string {
	return hash(identity.Commit + ":" + identity.RunID + ":" + strconv.Itoa(identity.RunAttempt) + ":" + suffix)
}

func configPolicy(config object, action string) error {
	if action != "rollback" {
		origin := str(config, "authentication", "web_client_url")
		parsed, err := url.Parse(origin)
		if err != nil || !originPattern.MatchString(origin) || parsed.User != nil || parsed.Path != "" || parsed.RawQuery != "" || parsed.Fragment != "" {
			return errors.New("authentication.web_client_url must be an HTTPS origin without credentials, path, query, fragment, or trailing slash")
		}
		if port := parsed.Port(); port != "" {
			number, err := strconv.Atoi(port)
			if err != nil || number < 0 || number > 65535 || number == 443 || strconv.Itoa(number) != port {
				return errors.New("authentication.web_client_url must be a canonical HTTPS origin")
			}
		}
		labels := strings.Split(parsed.Hostname(), ".")
		last := labels[len(labels)-1]
		if _, err := strconv.ParseUint(last, 0, 32); err == nil || strings.Trim(last, "0123456789") == "" {
			address, err := netip.ParseAddr(parsed.Hostname())
			if err != nil || !address.Is4() || address.String() != parsed.Hostname() {
				return errors.New("authentication.web_client_url has an invalid host")
			}
		}
	}
	zone := str(config, "database_zone")
	if len(zone) < 2 || zone[:len(zone)-2] != str(config, "region") {
		return errors.New("database_zone must belong to region")
	}
	for _, field := range []string{"private_ip", "data_disk_id"} {
		if at(config, "database_hosts", "authentication", field) == at(config, "database_hosts", "json_keys", field) {
			return errors.New("database hosts must use separate private addresses and data disks")
		}
	}
	return nil
}

// CompileRelease writes candidate, active, compensation, and execution inputs only
// after validating the complete transition. Files are manifest, config, prior receipt
// (or "-"), and output directory; optional receipt paths select rollback evidence.
func (compiler *Compiler) CompileRelease(files []string, identity Identity, action, priorManifest, currentReceipt string) error {
	if len(files) != 4 || (action != "deploy" && action != "rollback") {
		return errors.New("invalid release compilation arguments")
	}
	if err := identity.validate(); err != nil {
		return err
	}
	manifestBytes, err := os.ReadFile(files[0])
	if err != nil {
		return errors.New("cannot read image manifest")
	}
	value, err := decode(manifestBytes, true)
	manifest, ok := value.(object)
	if err != nil || !ok || compiler.validate("images", manifest) != nil {
		return errors.New("images is invalid")
	}
	if err = familyVersions(manifest); err != nil {
		return err
	}
	config, err := compiler.load(files[1], "release-config")
	if err != nil {
		return err
	}
	if err = configPolicy(config, action); err != nil {
		return err
	}
	var previous, current object
	if files[2] != "-" {
		previous, err = compiler.load(files[2], "receipt")
		if err != nil {
			return err
		}
	}
	current = previous
	if currentReceipt != "" && currentReceipt != "-" && currentReceipt != files[2] {
		current, err = compiler.load(currentReceipt, "receipt")
		if err != nil {
			return err
		}
	}
	if action == "rollback" && (previous == nil || current == nil) {
		return errors.New("rollback requires an exact prior and current receipt")
	}

	previousActive := obj(previous, "activeTfvars", "application_release")
	var previousManifest object
	if previousActive != nil {
		previousManifest = obj(previous, "imageManifest")
		if previousManifest == nil && priorManifest != "" {
			previousManifest, err = compiler.load(priorManifest, "images")
			if err != nil {
				return err
			}
		}
		if compiler.validate("images", previousManifest) != nil {
			return errors.New("prior receipt requires its exact image manifest")
		}
		if err = familyVersions(previousManifest); err != nil {
			return err
		}
		if err = verifyReceiptManifest(config, previousManifest, previous); err != nil {
			return err
		}
	}
	changed := []string{}
	if action == "deploy" && previousManifest != nil {
		changed, err = imageChanges(previousManifest, manifest)
		if err != nil {
			return err
		}
	}
	services := []string{"json_keys", "authentication"}
	if len(changed) == 1 {
		services = changed
	}
	legacy := obj(previous, "database") != nil && obj(previous, "database", "hosts") == nil
	rebuild := legacy && action == "deploy"
	if rebuild && len(changed) > 0 {
		return errors.New("rebuild the legacy database topology separately from service image updates")
	}
	for _, receipt := range []object{previous, current} {
		if obj(receipt, "database") == nil {
			continue
		}
		if obj(receipt, "database", "hosts") == nil {
			if action == "rollback" {
				return errors.New("rollback cannot target the retired shared database")
			}
		} else if !reflect.DeepEqual(at(receipt, "activeTfvars", "database_hosts"), config["database_hosts"]) {
			return errors.New("database disk identity or address differs from the receipt; use protected recovery")
		}
	}

	seed := identity.seed(identity.Nonce)
	candidateTag := "c-" + hash(seed + ":candidate")[:16]
	revisions := object{"authentication": "agora-authentication-rest-" + seed[:12], "jsonKeys": "agora-json-keys-grpc-" + seed[12:24]}
	base := object{}
	for _, key := range []string{"management_project_id", "workload_project_id", "region", "backup_bucket_name", "database_hosts", "network_id", "subnet_id", "cloud_run_invocation_tags"} {
		base[key] = config[key]
	}
	base["runtime_service_accounts"] = runtimeAccounts(str(config, "workload_project_id"))
	previousDatabase := obj(previous, "database")
	if rebuild {
		previousDatabase = nil
	}
	database := object{"releaseRevision": identity.Commit}
	databaseHosts, databaseReleases, application := object{}, object{}, object{}
	unchangedDatabase := previousDatabase != nil
	for _, family := range families {
		service, prefix := family.service, family.prefix
		images := obj(manifest, "components", component(service), "images")
		database[prefix+"Image"] = promoted(config, obj(images, "database"))
		database[prefix+"PasswordVersion"] = at(config, "secret_versions", service+"_postgres_password")
		database[prefix+"BackupPasswordVersion"] = at(config, "secret_versions", service+"_postgres_backup_password")
		priorHost := obj(previousDatabase, "hosts", service)
		unchanged := priorHost != nil
		for _, suffix := range []string{"Image", "PasswordVersion", "BackupPasswordVersion"} {
			same := reflect.DeepEqual(database[prefix+suffix], previousDatabase[prefix+suffix])
			unchanged = unchanged && same
			unchangedDatabase = unchangedDatabase && same
		}
		host := object{"privateIp": at(config, "database_hosts", service, "private_ip"), "dataDiskId": at(config, "database_hosts", service, "data_disk_id"), "releaseRevision": identity.Commit}
		if unchanged {
			host["releaseRevision"] = priorHost["releaseRevision"]
		}
		databaseHosts[service] = host
		databaseReleases[service] = object{"image": database[prefix+"Image"], "backup_password_version": database[prefix+"BackupPasswordVersion"]}
		appImages := object{}
		for _, slot := range family.slots {
			if slot != "database" {
				appImages[imageKey(slot)] = promoted(config, obj(images, slot))
			}
		}
		application[service] = object{"images": appImages, "revision": revisions[prefix], "active_revision": revisions[prefix], "secrets": object{"postgres_password_version": database[prefix+"PasswordVersion"]}}
	}
	if unchangedDatabase {
		database["releaseRevision"] = previousDatabase["releaseRevision"]
	}
	database["hosts"] = databaseHosts
	authentication := obj(application, "authentication")
	for _, key := range []string{"smtp", "super_admin_email", "web_client_url"} {
		if value, exists := obj(config, "authentication")[key]; exists {
			authentication[key] = value
		}
	}
	for _, secret := range []string{"smtp_password", "super_admin_password"} {
		obj(authentication, "secrets")[secret+"_version"] = at(config, "secret_versions", "authentication_"+secret)
	}
	obj(application, "json_keys", "secrets")["app_master_key_version"] = at(config, "secret_versions", "json_keys_app_master_key")
	application["rollout"] = object{"candidate_tag": candidateTag, "phase": "active", "services": services}
	active := clone(base)
	active["database_releases"], active["application_release"] = databaseReleases, application
	candidate := clone(active)
	obj(candidate, "application_release", "rollout")["phase"] = "candidate"
	for _, family := range families {
		app := obj(candidate, "application_release", family.service)
		if revision := str(previousActive, family.service, "active_revision"); revision != "" {
			app["active_revision"] = revision
		} else {
			delete(app, "active_revision")
		}
	}
	if len(services) == 1 {
		for key, value := range base {
			if !reflect.DeepEqual(value, at(previous, "activeTfvars", key)) {
				return errors.New("shared inputs changed alongside an image release; deploy configuration separately")
			}
		}
		for _, family := range families {
			if family.service == services[0] {
				continue
			}
			oldConfig, nextConfig := clone(obj(previousActive, family.service)), clone(obj(application, family.service))
			for _, value := range []object{oldConfig, nextConfig} {
				delete(value, "revision")
				delete(value, "active_revision")
			}
			if !reflect.DeepEqual(oldConfig, nextConfig) || !reflect.DeepEqual(databaseReleases[family.service], at(previous, "activeTfvars", "database_releases", family.service)) {
				return errors.New("peer inputs changed alongside another service's images; deploy configuration separately")
			}
			revisions[family.prefix] = at(previousActive, family.service, "revision")
			for _, tfvars := range []object{candidate, active} {
				obj(tfvars, "application_release")[family.service] = copyValue(previousActive[family.service])
			}
		}
	}
	rollback := clone(base)
	rollback["database_releases"], rollback["application_release"] = object{}, nil
	if previousActive != nil {
		rollback = clone(obj(previous, "activeTfvars"))
		obj(rollback, "application_release")["rollout"] = object{"candidate_tag": candidateTag, "phase": "active", "services": services}
		for _, service := range services {
			name, suffix := "agora-authentication-rest-", ":rollback-auth"
			if service == "json_keys" {
				name, suffix = "agora-json-keys-grpc-", ":rollback-json"
			}
			obj(rollback, "application_release", service)["revision"] = name + hash(seed + suffix)[:12]
		}
	}
	if rebuild {
		rollback = clone(candidate)
	}
	targetApplication, targetDatabase := application, database
	mode := "maintenance"
	switch {
	case action == "rollback":
		mode = "rollback"
		targetApplication, targetDatabase = obj(rollback, "application_release"), obj(previous, "database")
	case rebuild:
		mode = "database-rebuild"
	case previousActive == nil:
		mode = "first-launch"
	case len(changed) > 0:
		mode = "service"
	}
	currentDatabase := obj(current, "database")
	if rebuild {
		currentDatabase = nil
	}
	release := object{
		"schemaVersion": 1, "action": action, "services": services, "mode": mode,
		"imageManifest": manifest, "previousManifest": previousManifest,
		"commit": identity.Commit, "runId": identity.RunID, "runAttempt": identity.RunAttempt,
		"manifestSha256": hash(string(manifestBytes)), "postgresMajor": manifest["postgresMajor"],
		"cloud":        object{"managementProjectId": config["management_project_id"], "workloadProjectId": config["workload_project_id"], "region": config["region"], "databaseZone": config["database_zone"], "databaseHosts": config["database_hosts"], "quotaExpectations": config["quota_expectations"], "secretVersions": secretVersions(targetApplication, targetDatabase)},
		"candidateTag": candidateTag, "revisions": revisions, "images": normalizedImages(config, manifest),
		"database": database, "currentDatabase": currentDatabase, "previousDatabase": previousDatabase,
	}
	return writeOutputs(files[3], map[string]any{"release.json": release, "candidate.tfvars.json": candidate, "active.tfvars.json": active, "rollback.tfvars.json": rollback})
}
