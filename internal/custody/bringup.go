package custody

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	"google.golang.org/api/compute/v1"
)

// bringUp runs only after guarded apply and convergence. The provider owns the
// stateful replacement; systemd owns process startup and database readiness.
func (storage store) bringUp(inputs string, data []byte) error {
	path := filepath.Join(storage.scratch, "outputs.json")
	if err := storage.execute(storage.ctx, io.Discard, "env", "ALLOW_RESOURCE_DELETION=false", "TOFU_VAR_FILE="+inputs,
		"./ops/tofu-gate.sh", "output", "service-foundation", storage.bucket, path); err != nil {
		return err
	}
	var outputs struct {
		Native struct {
			Value struct {
				Project, Zone, Group, Template, Image string
				TemplateID                            string `json:"template_id"`
				Database, Repository                  maintenanceHost
			}
		} `json:"native_bringup"`
	}
	var config struct {
		Project string `json:"project_id"`
	}
	encoded, err := os.ReadFile(path)
	if err != nil || json.Unmarshal(encoded, &outputs) != nil || json.Unmarshal(data, &config) != nil {
		return errors.New("native bring-up outputs unavailable")
	}
	target := outputs.Native.Value
	if target.Project != config.Project || target.Group != "agora-database-json-keys" ||
		target.Repository.Name != "agora-pgbackrest-json-keys" || !strings.HasPrefix(target.Database.Name, target.Group+"-") {
		return errors.New("native bring-up scope differs from registration")
	}
	prefix := "https://www.googleapis.com/compute/v1/projects/" + target.Project
	if !regexp.MustCompile(`^`+regexp.QuoteMeta(prefix)+`/global/instanceTemplates/[a-z0-9-]+$`).MatchString(target.Template) ||
		!regexp.MustCompile(`^[1-9][0-9]{0,19}$`).MatchString(target.TemplateID) ||
		!regexp.MustCompile(`^europe-west1-docker[.]pkg[.]dev/`+regexp.QuoteMeta(target.Project)+`/agora-production/service-json-keys/database@sha256:[a-f0-9]{64}$`).MatchString(target.Image) {
		return errors.New("invalid native template or image")
	}
	target.Repository.repository = true
	hosts := []maintenanceHost{target.Repository, target.Database}
	for index := range hosts {
		hosts[index].Project, hosts[index].Zone = target.Project, target.Zone
		if err := hosts[index].validate(); err != nil {
			return err
		}
	}
	var members bytes.Buffer
	if err := storage.execute(storage.ctx, &members, "gcloud", "compute", "instance-groups", "managed", "list-instances", target.Group,
		"--project="+target.Project, "--zone="+target.Zone, "--format=json", "--quiet"); err != nil {
		return err
	}
	var managed []compute.ManagedInstance
	if json.Unmarshal(members.Bytes(), &managed) != nil || len(managed) != 1 {
		return errors.New("native group must have exactly one reconciled member")
	}
	member := managed[0]
	if member.Instance != prefix+"/zones/"+target.Zone+"/instances/"+target.Database.Name ||
		strconv.FormatUint(member.Id, 10) != target.Database.InstanceID || member.CurrentAction != "NONE" || member.InstanceStatus != "RUNNING" {
		return errors.New("native managed member is not reconciled")
	}
	if member.Version == nil || (member.Version.InstanceTemplate != target.Template &&
		member.Version.InstanceTemplate != prefix+"/global/instanceTemplates/"+target.TemplateID) {
		return errors.New("native managed member has the wrong template")
	}
	// The provider's self_link_unique carries a query suffix, not an API URL.
	// Bind the API's name/ID reference to the immutable ID in the private output.
	var templateJSON bytes.Buffer
	if err := storage.execute(storage.ctx, &templateJSON, "gcloud", "compute", "instance-templates", "describe", filepath.Base(target.Template),
		"--project="+target.Project, "--format=json", "--quiet"); err != nil {
		return err
	}
	var template compute.InstanceTemplate
	if json.Unmarshal(templateJSON.Bytes(), &template) != nil || template.SelfLink != target.Template ||
		strconv.FormatUint(template.Id, 10) != target.TemplateID {
		return errors.New("native template incarnation changed")
	}
	for _, host := range hosts {
		if status, err := storage.observeHost(host); err != nil || status != "RUNNING" {
			return errors.New("native host identity, runtime or running state is unconfirmed")
		}
	}
	for _, host := range hosts {
		if host.repository {
			// COS installs /etc from current metadata at boot. A metadata-only apply
			// leaves old loaded units behind; restart this already-quiesced VM once.
			for _, action := range []string{"stop", "start"} {
				if err := storage.execute(storage.ctx, io.Discard, "gcloud", "compute", "instances", action, host.Name,
					"--project="+host.Project, "--zone="+host.Zone, "--quiet"); err != nil {
					return err
				}
				want := "TERMINATED"
				if action == "start" {
					want = "RUNNING"
				}
				if status, err := storage.observeHost(host); err != nil || status != want {
					return errors.New("repository restart unconfirmed")
				}
			}
		}
		if _, err := storage.hostSSH(host, "sudo -n timeout 180s cloud-init status --wait"); err != nil {
			return err
		}
		loaded, err := storage.hostSSH(host, "sudo -n cat /var/lib/cloud/instance/user-data.txt")
		if err != nil || strings.TrimSpace(loaded) != strings.TrimSpace(host.Metadata["user-data"]) {
			return errors.New("booted native configuration differs from the reviewed runtime")
		}
		if _, err := storage.hostSSH(host, "sudo -n timeout 360s systemctl start "+host.unit()); err != nil {
			return err
		}
		if err := storage.hostUnit(host, host.unit(), "active"); err != nil {
			return err
		}
	}
	database := hosts[1]
	result, err := storage.hostSSH(database, `sudo -n docker inspect --format '{{.State.Running}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}|{{.Config.Image}}|{{.HostConfig.RestartPolicy.Name}}' agora-postgres-json-keys`)
	if err != nil || strings.TrimSpace(result) != "true|healthy|"+target.Image+"|no" {
		return errors.New("native database image or health is unconfirmed")
	}
	// An authenticated read also exercises TLS and the repository's GCS identity.
	if _, err := storage.hostSSH(database, "sudo -n timeout 90s docker exec --user=999:999 agora-postgres-json-keys pgbackrest --stanza=json-keys --io-timeout=10 --log-level-file=off --log-level-console=error --output=json repo-ls"); err != nil {
		return err
	}
	for _, name := range []string{"full", "diff", "check"} {
		if err := storage.hostUnit(database, "agora-backup-"+name+".timer", "inactive"); err != nil {
			return err
		}
	}
	return nil
}
