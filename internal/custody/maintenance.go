package custody

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"

	"google.golang.org/api/compute/v1"
)

// Targets come only from the reviewed plan's prior state, never a caller-supplied
// host name. A template change does not prove that its MIG member was replaced.
type maintenanceHost struct {
	Name       string            `json:"name"`
	Project    string            `json:"project"`
	Zone       string            `json:"zone"`
	InstanceID string            `json:"instance_id"`
	Metadata   map[string]string `json:"metadata"`
	repository bool
}

func plannedMaintenance(path string, inputs []byte, getenv func(string) string) ([]maintenanceHost, error) {
	var plan struct {
		Format  string `json:"format_version"`
		Changes []struct {
			Address string
			Change  struct{ Actions []string }
		} `json:"resource_changes"`
		Prior struct {
			Values struct {
				Root struct {
					Resources []struct {
						Address string
						Values  maintenanceHost
					}
				} `json:"root_module"`
			}
		} `json:"prior_state"`
	}
	data, err := os.ReadFile(path)
	if err != nil || json.Unmarshal(data, &plan) != nil || !strings.HasPrefix(plan.Format, "1.") {
		return nil, failure{65, "Foundation maintenance requires a readable native plan."}
	}
	disruptive := false
	for _, change := range plan.Changes {
		switch change.Address {
		case `google_compute_instance.repository["host"]`, `google_compute_instance_template.database["host"]`,
			`google_compute_instance_group_manager.database["host"]`, `google_compute_disk.database["host"]`:
			disruptive = disruptive || !slices.Equal(change.Change.Actions, []string{"no-op"})
		}
	}
	if !disruptive {
		return nil, nil
	}
	resources := map[string]maintenanceHost{}
	for _, resource := range plan.Prior.Values.Root.Resources {
		resources[resource.Address] = resource.Values
	}
	var config struct {
		Project string           `json:"project_id"`
		Service string           `json:"service"`
		Runtime *json.RawMessage `json:"database_runtime"`
	}
	if err := json.Unmarshal(inputs, &config); err != nil {
		return nil, err
	}
	template := resources[`google_compute_instance_template.database["host"]`]
	repository, hasRepository := resources[`google_compute_instance.repository["host"]`]
	native := config.Runtime != nil || strings.Contains(template.Metadata["user-data"], "/etc/agora-database/") ||
		strings.Contains(repository.Metadata["user-data"], "/etc/agora-backup/")
	if !native {
		return nil, nil
	} // Existing legacy maintenance keeps its own owner.
	var hosts []maintenanceHost
	if _, exists := resources[`google_compute_instance_group_manager.database["host"]`]; exists {
		host, found := resources[`data.google_compute_instance.database["host"]`]
		if !found || config.Runtime == nil {
			return nil, failure{65, "Native/legacy host handoff requires separate maintenance review."}
		}
		hosts = append(hosts, host)
	}
	if hasRepository {
		repository.repository = true
		hosts = append(hosts, repository)
	}
	for _, host := range hosts {
		unit := "agora-database.service"
		if host.repository {
			unit = "agora-backup-repository.service"
		}
		if config.Service != "json-keys" || host.Project != config.Project || !serviceScopePattern.MatchString("services/"+host.Project) {
			return nil, failure{65, "Maintenance target differs from the registered service."}
		}
		if !regexp.MustCompile(`^[a-z][a-z0-9-]{0,61}[a-z0-9]$`).MatchString(host.Name) ||
			!regexp.MustCompile(`^[1-9][0-9]{0,19}$`).MatchString(host.InstanceID) ||
			!slices.Contains([]string{"europe-west1-b", "europe-west1-c", "europe-west1-d"}, host.Zone) {
			return nil, failure{65, "Maintenance target has invalid resource coordinates."}
		}
		if !strings.Contains(host.Metadata["user-data"], "/etc/systemd/system/"+unit) {
			return nil, failure{65, "Maintenance requires the prepared native units on every existing host."}
		}
	}
	if len(hosts) > 0 && (getenv("NATIVE_BACKUP_MAINTENANCE_ENABLED") != "true" ||
		getenv("GITHUB_WORKFLOW_REF") != "a-novel/infra/.github/workflows/foundation.yaml@refs/heads/master" ||
		getenv("GITHUB_EVENT_NAME") != "workflow_dispatch") {
		return nil, failure{77, "Native host maintenance requires separate activation in the protected foundation workflow."}
	}
	return hosts, nil
}

// quiesce has no retry or restart path. A lost SSH response can leave systemd
// working; the caller must retain admission instead of interpreting it as idle.
func (storage store) quiesce(host maintenanceHost) error {
	var observed bytes.Buffer
	if err := storage.execute(storage.ctx, &observed, "gcloud", "compute", "instances", "describe", host.Name,
		"--project="+host.Project, "--zone="+host.Zone, "--format=json", "--quiet"); err != nil {
		return err
	}
	var vm compute.Instance
	if err := json.Unmarshal(observed.Bytes(), &vm); err != nil {
		return err
	}
	if strconv.FormatUint(vm.Id, 10) != host.InstanceID || vm.Name != host.Name ||
		vm.Zone != "https://www.googleapis.com/compute/v1/projects/"+host.Project+"/zones/"+host.Zone {
		return errors.New("maintenance host incarnation changed")
	}
	metadata := map[string]string{}
	if vm.Metadata != nil {
		for _, item := range vm.Metadata.Items {
			if item.Value != nil {
				metadata[item.Key] = *item.Value
			}
		}
	}
	if metadata["user-data"] != host.Metadata["user-data"] || metadata["startup-script"] != "" || metadata["startup-script-url"] != "" {
		return errors.New("maintenance host runtime changed")
	}
	if vm.Status == "TERMINATED" {
		return nil
	}
	if vm.Status != "RUNNING" {
		return errors.New("maintenance host is transitioning")
	}
	ssh := func(command string) (string, error) {
		var output bytes.Buffer
		// Recheck the incarnation on the endpoint, closing name reuse between describe and SSH.
		command = `test "$(curl -q --fail --silent --show-error --noproxy '*' --connect-timeout 5 --max-time 10 -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/id)" = '` + host.InstanceID + `' && ` + command
		err := storage.execute(storage.ctx, &output, "gcloud", "compute", "ssh", host.Name,
			"--project="+host.Project, "--zone="+host.Zone, "--quiet", "--tunnel-through-iap", "--ssh-key-expire-after=1h",
			"--ssh-key-file="+filepath.Join(storage.scratch, "maintenance-key"), "--ssh-flag=-o ConnectTimeout=15", "--command="+command)
		return output.String(), err
	}
	groups := [][]string{
		{"agora-backup-full.timer", "agora-backup-diff.timer", "agora-backup-check.timer"},
		{"agora-backup-stanza-create.service", "agora-backup-check.service", "agora-backup-full.service", "agora-backup-diff.service", "agora-backup-verify.service"},
		{"agora-database.service"},
	}
	if host.repository {
		groups = [][]string{{"agora-backup-repository.service"}}
	}
	for _, units := range groups {
		if _, err := ssh("sudo -n timeout 180s systemctl stop " + strings.Join(units, " ")); err != nil {
			return err
		}
	}
	for _, units := range groups {
		for _, unit := range units {
			result, err := ssh("sudo -n systemctl show --all --property=LoadState,ActiveState,Job " + unit)
			if err != nil {
				return err
			}
			fields := strings.Fields(result)
			slices.Sort(fields)
			if !slices.Equal(fields, []string{"ActiveState=inactive", "Job=", "LoadState=loaded"}) {
				return errors.New("native unit is missing, busy or not stopped")
			}
		}
	}
	result, err := ssh("sudo -n docker ps --format '{{.Names}}'")
	if err != nil {
		return err
	}
	for _, name := range strings.Fields(result) {
		if strings.HasPrefix(name, "agora-backup-") || name == "agora-postgres-json-keys" || name == "agora-database-credentials" {
			return errors.New("native container still running")
		}
	}
	return nil
}
