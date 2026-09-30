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

// Targets come from reviewed prior state for quiescence or private converged
// outputs for bring-up, never caller-supplied host names.
type maintenanceHost struct {
	Name       string            `json:"name"`
	Project    string            `json:"project"`
	Zone       string            `json:"zone"`
	InstanceID string            `json:"instance_id"`
	Metadata   map[string]string `json:"metadata"`
	repository bool
}

type maintenance struct {
	hosts   []maintenanceHost
	bringUp bool
}

func plannedMaintenance(path string, inputs []byte, getenv func(string) string) (maintenance, error) {
	var config struct {
		Project string `json:"project_id"`
		Service string `json:"service"`
		Runtime *struct {
			BringUp bool `json:"bring_up"`
		} `json:"database_runtime"`
	}
	if err := json.Unmarshal(inputs, &config); err != nil {
		return maintenance{}, err
	}
	approved := getenv("NATIVE_BACKUP_MAINTENANCE_ENABLED") == "true" &&
		getenv("GITHUB_WORKFLOW_REF") == "a-novel/infra/.github/workflows/foundation.yaml@refs/heads/master" &&
		getenv("GITHUB_EVENT_NAME") == "workflow_dispatch"
	bringUp := config.Runtime != nil && config.Runtime.BringUp
	if bringUp && (!approved || getenv("NATIVE_BACKUP_BRINGUP_ENABLED") != "true" || config.Service != "json-keys") {
		return maintenance{}, failure{77, "Native bring-up requires separate activation in the protected foundation workflow."}
	}
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
		return maintenance{}, failure{65, "Foundation maintenance requires a readable native plan."}
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
		return maintenance{}, nil
	}
	resources := map[string]maintenanceHost{}
	for _, resource := range plan.Prior.Values.Root.Resources {
		resources[resource.Address] = resource.Values
	}
	template := resources[`google_compute_instance_template.database["host"]`]
	repository, hasRepository := resources[`google_compute_instance.repository["host"]`]
	native := config.Runtime != nil || strings.Contains(template.Metadata["user-data"], "/etc/agora-database/") ||
		strings.Contains(repository.Metadata["user-data"], "/etc/agora-backup/")
	if !native {
		return maintenance{}, nil
	} // Existing legacy maintenance keeps its own owner.
	var hosts []maintenanceHost
	if _, exists := resources[`google_compute_instance_group_manager.database["host"]`]; exists {
		host, found := resources[`data.google_compute_instance.database["host"]`]
		if !found || config.Runtime == nil {
			return maintenance{}, failure{65, "Native/legacy host handoff requires separate maintenance review."}
		}
		hosts = append(hosts, host)
	}
	if hasRepository {
		repository.repository = true
		hosts = append(hosts, repository)
	}
	for _, host := range hosts {
		if config.Service != "json-keys" || host.Project != config.Project || host.validate() != nil {
			return maintenance{}, failure{65, "Maintenance requires valid registered targets with prepared native units."}
		}
	}
	if len(hosts) > 0 && !approved {
		return maintenance{}, failure{77, "Native host maintenance requires separate activation in the protected foundation workflow."}
	}
	return maintenance{hosts, bringUp}, nil
}

func (host maintenanceHost) unit() string {
	if host.repository {
		return "agora-backup-repository.service"
	}
	return "agora-database.service"
}

func (host maintenanceHost) validate() error {
	if !serviceScopePattern.MatchString("services/"+host.Project) ||
		!regexp.MustCompile(`^[a-z][a-z0-9-]{0,61}[a-z0-9]$`).MatchString(host.Name) ||
		!regexp.MustCompile(`^[1-9][0-9]{0,19}$`).MatchString(host.InstanceID) ||
		!slices.Contains([]string{"europe-west1-b", "europe-west1-c", "europe-west1-d"}, host.Zone) {
		return errors.New("invalid native host coordinates")
	}
	if !strings.Contains(host.Metadata["user-data"], "/etc/systemd/system/"+host.unit()) {
		return errors.New("native host units missing")
	}
	return nil
}

func (storage store) observeHost(host maintenanceHost) (string, error) {
	var observed bytes.Buffer
	if err := storage.execute(storage.ctx, &observed, "gcloud", "compute", "instances", "describe", host.Name,
		"--project="+host.Project, "--zone="+host.Zone, "--format=json", "--quiet"); err != nil {
		return "", err
	}
	var vm compute.Instance
	if err := json.Unmarshal(observed.Bytes(), &vm); err != nil {
		return "", err
	}
	if strconv.FormatUint(vm.Id, 10) != host.InstanceID || vm.Name != host.Name ||
		vm.Zone != "https://www.googleapis.com/compute/v1/projects/"+host.Project+"/zones/"+host.Zone {
		return "", errors.New("maintenance host incarnation changed")
	}
	metadata := map[string]string{}
	if vm.Metadata != nil {
		for _, item := range vm.Metadata.Items {
			if item.Value != nil {
				metadata[item.Key] = *item.Value
			}
		}
	}
	if metadata["startup-script"] != "" || metadata["startup-script-url"] != "" {
		return "", errors.New("unexpected native startup script")
	}
	for key, value := range host.Metadata {
		if metadata[key] != value {
			return "", errors.New("maintenance host runtime changed")
		}
	}
	return vm.Status, nil
}

func (storage store) hostSSH(host maintenanceHost, command string) (string, error) {
	var output bytes.Buffer
	// Recheck the incarnation on the endpoint, closing name reuse between describe and SSH.
	command = `test "$(curl -q --fail --silent --show-error --noproxy '*' --connect-timeout 5 --max-time 10 -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/id)" = '` + host.InstanceID + `' && ` + command
	err := storage.execute(storage.ctx, &output, "gcloud", "compute", "ssh", host.Name,
		"--project="+host.Project, "--zone="+host.Zone, "--quiet", "--tunnel-through-iap", "--ssh-key-expire-after=1h",
		"--ssh-key-file="+filepath.Join(storage.scratch, "maintenance-key"), "--ssh-flag=-o ConnectTimeout=15",
		"--ssh-flag=-o ConnectionAttempts=6", "--command="+command)
	return output.String(), err
}

// quiesce has no retry path. A lost SSH response can leave systemd working;
// the caller retains admission instead of interpreting it as idle.
func (storage store) quiesce(host maintenanceHost) error {
	status, err := storage.observeHost(host)
	if err != nil || status == "TERMINATED" {
		return err
	}
	if status != "RUNNING" {
		return errors.New("maintenance host is transitioning")
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
		if _, err := storage.hostSSH(host, "sudo -n timeout 180s systemctl stop "+strings.Join(units, " ")); err != nil {
			return err
		}
	}
	for _, units := range groups {
		for _, unit := range units {
			if err := storage.hostUnit(host, unit, "inactive"); err != nil {
				return err
			}
		}
	}
	result, err := storage.hostSSH(host, "sudo -n docker ps --format '{{.Names}}'")
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

func (storage store) hostUnit(host maintenanceHost, unit, state string) error {
	result, err := storage.hostSSH(host, "sudo -n systemctl show --all --property=LoadState,ActiveState,Job "+unit)
	if err != nil {
		return err
	}
	fields := strings.Fields(result)
	slices.Sort(fields)
	if !slices.Equal(fields, []string{"ActiveState=" + state, "Job=", "LoadState=loaded"}) {
		return errors.New("native unit is missing, busy or in the wrong state")
	}
	return nil
}
