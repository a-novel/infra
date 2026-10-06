package recovery

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"

	"google.golang.org/api/compute/v1"
)

const (
	hostName  = "agora-native-recovery"
	diskName  = "agora-native-recovery-data"
	diskPath  = "/dev/disk/by-id/google-" + diskName
	mountPath = "/mnt/disks/agora-recovery"
)

// Target comes from the exact state generation recorded by host preparation.
// Numeric resource identities prevent reuse of a deleted host or disk's name.
type Target struct {
	Project        string  `json:"project"`
	Zone           string  `json:"zone"`
	Host           string  `json:"host"`
	Disk           string  `json:"disk"`
	InstanceID     string  `json:"instance_id"`
	DiskID         string  `json:"disk_id"`
	UserDataSHA256 string  `json:"user_data_sha256"`
	Request        Request `json:"request"`
}

// Validate checks prepared coordinates before they can become command arguments.
func (target Target) Validate() error {
	if target.Request.Validate() != nil || target.Project != target.Request.Project ||
		!slices.Contains([]string{"europe-west1-b", "europe-west1-c", "europe-west1-d"}, target.Zone) {
		return errors.New("invalid prepared recovery scope")
	}
	if target.Host != hostName || target.Disk != diskName || !matches(`[a-f0-9]{64}`, target.UserDataSHA256) ||
		!matches(`[1-9][0-9]{0,19}`, target.InstanceID) || !matches(`[1-9][0-9]{0,19}`, target.DiskID) {
		return errors.New("invalid prepared recovery resource identities")
	}
	return nil
}

// Host waits for SSH readiness before running a one-shot systemd worker.
// Its caller must already hold admission and a create-only destination reservation.
type Host struct {
	Target  Target
	DiskGiB int
	Image   string
	Scratch string
	Execute func(context.Context, io.Writer, string, ...string) error
}

// Restore prepares a blank named disk, completes the selected recovery and stops the host.
// On any error it leaves the attempt intact: an SSH failure can mean work is still running.
func (host Host) Restore(ctx context.Context) (map[string]string, error) {
	if err := host.Target.Validate(); err != nil {
		return nil, err
	}
	if host.DiskGiB < 10 || host.DiskGiB > 100 || !matches(`europe-west1-docker[.]pkg[.]dev/`+host.Target.Project+`/agora-tooling/native-restore@sha256:[a-f0-9]{64}`, host.Image) {
		return nil, errors.New("invalid recovery disk or image")
	}
	if err := host.check(ctx, "TERMINATED"); err != nil {
		return nil, err
	}
	if _, err := host.cloud(ctx, "instances", "start", hostName); err != nil {
		return nil, err
	}
	if err := host.check(ctx, "RUNNING"); err != nil {
		return nil, err
	}
	if err := host.waitSSH(ctx); err != nil {
		return nil, err
	}
	// Cloud-init installs the disabled unit. Waiting does not start it.
	if _, err := host.ssh(ctx, "sudo -n cloud-init status --wait"); err != nil {
		return nil, err
	}
	request, err := host.ssh(ctx, "sudo -n cat /etc/agora-recovery/request.json")
	var actual Request
	if err != nil || json.Unmarshal(request, &actual) != nil || actual != host.Target.Request {
		return nil, errors.New("host request differs from the prepared selection")
	}
	if err := host.prepareDisk(ctx); err != nil {
		return nil, err
	}
	if err := host.worker(ctx, "restore", "bridge"); err != nil {
		return nil, err
	}
	names := []string{"request.json", "catalog.json", "restore.log", "files-restored.json"}
	if host.Target.Request.VerifySQL {
		if err := host.worker(ctx, "verify", "none"); err != nil {
			return nil, err
		}
		names = append(names, "verification/postgres.log", "verification/sql-verified.json")
	}
	evidence := map[string]string{}
	for _, name := range names {
		data, err := host.ssh(ctx, "sudo -n cat "+mountPath+"/work/attempt/"+name)
		if err != nil {
			return nil, err
		}
		evidence[name] = string(data)
	}
	if err := host.Target.Request.CheckEvidence(evidence); err != nil {
		return nil, err
	}
	if _, err := host.cloud(ctx, "instances", "stop", hostName); err != nil {
		return nil, err
	}
	if err := host.check(ctx, "TERMINATED"); err != nil {
		return nil, err
	}
	return evidence, nil
}

// waitSSH probes only connectivity: Compute RUNNING precedes guest SSH readiness.
// Disk preparation and worker commands must never enter this retry loop.
func (host Host) waitSSH(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()
	for ctx.Err() == nil {
		if _, err := host.ssh(ctx, "true"); err == nil {
			return ctx.Err()
		}
		timer := time.NewTimer(5 * time.Second)
		select {
		case <-ctx.Done():
			timer.Stop()
		case <-timer.C:
		}
	}
	return fmt.Errorf("recovery SSH readiness unconfirmed; retain guard: %w", ctx.Err())
}

func (host Host) worker(ctx context.Context, name, network string) error {
	if _, err := host.ssh(ctx, "sudo -n systemctl start agora-native-"+name+".service"); err != nil {
		return err
	}
	result, err := host.ssh(ctx, `sudo -n docker inspect --format '{{.State.Status}}|{{.State.ExitCode}}|{{.Config.Image}}|{{.HostConfig.RestartPolicy.Name}}|{{.HostConfig.NetworkMode}}' agora-native-`+name)
	if err != nil || strings.TrimSpace(string(result)) != "exited|0|"+host.Image+"|no|"+network {
		return errors.New("recovery container completion or network boundary is unconfirmed")
	}
	return nil
}

// CheckFiles verifies a worker's files-only completion, never database startup or SQL recovery.
func (request Request) CheckFiles(files map[string]string) error {
	var actual Request
	var result struct {
		SystemID string `json:"system_id"`
		Set      string `json:"set"`
		Started  *bool  `json:"postgresql_started"`
	}
	if json.Unmarshal([]byte(files["request.json"]), &actual) != nil || actual != request ||
		request.CheckCatalog([]byte(files["catalog.json"])) != nil {
		return errors.New("restore evidence differs from the selected database and backup")
	}
	if json.Unmarshal([]byte(files["files-restored.json"]), &result) != nil || result.Started == nil || *result.Started ||
		result.SystemID != request.SystemID || result.Set != request.Set {
		return errors.New("files-only completion is unconfirmed")
	}
	return nil
}

// CheckStopped reuses the exact prepared VM and disk checks before project cleanup.
// It neither starts the host nor reads its database files.
func (host Host) CheckStopped(ctx context.Context) error {
	if err := host.Target.Validate(); err != nil {
		return err
	}
	return host.check(ctx, "TERMINATED")
}

func (host Host) check(ctx context.Context, status string) error {
	data, err := host.cloud(ctx, "instances", "describe", hostName, "--format=json")
	var vm compute.Instance
	if err != nil || json.Unmarshal(data, &vm) != nil {
		return errors.New("recovery host observation unavailable")
	}
	target := host.Target
	base := "https://www.googleapis.com/compute/v1/projects/" + target.Project + "/"
	zonal := base + "zones/" + target.Zone + "/"
	if strconv.FormatUint(vm.Id, 10) != target.InstanceID || vm.Name != hostName || vm.Status != status ||
		vm.Zone != strings.TrimSuffix(zonal, "/") || vm.MachineType != zonal+"machineTypes/e2-medium" || vm.CanIpForward {
		return errors.New("recovery host identity or state changed")
	}
	if len(vm.ServiceAccounts) != 1 || vm.ServiceAccounts[0].Email != target.Request.Identity() ||
		!slices.Equal(vm.ServiceAccounts[0].Scopes, []string{"https://www.googleapis.com/auth/cloud-platform"}) {
		return errors.New("recovery host identity boundary changed")
	}
	if len(vm.NetworkInterfaces) != 1 {
		return errors.New("recovery host network changed")
	}
	nic := vm.NetworkInterfaces[0]
	if nic.Network != base+"global/networks/"+hostName || nic.Subnetwork != base+"regions/europe-west1/subnetworks/"+hostName ||
		len(nic.AccessConfigs)+len(nic.Ipv6AccessConfigs) != 0 {
		return errors.New("recovery host is not private")
	}
	schedule := vm.Scheduling
	if schedule == nil || schedule.AutomaticRestart == nil || *schedule.AutomaticRestart || schedule.MaxRunDuration == nil ||
		schedule.MaxRunDuration.Seconds != 14400 || schedule.InstanceTerminationAction != "STOP" {
		return errors.New("recovery host runtime cap changed")
	}
	shield := vm.ShieldedInstanceConfig
	if shield == nil || !shield.EnableSecureBoot || !shield.EnableVtpm || !shield.EnableIntegrityMonitoring {
		return errors.New("recovery host boot protections changed")
	}
	metadata := map[string]string{}
	if vm.Metadata != nil {
		for _, item := range vm.Metadata.Items {
			if item.Value != nil {
				metadata[item.Key] = *item.Value
			}
		}
	}
	for key, value := range map[string]string{"enable-oslogin": "TRUE", "block-project-ssh-keys": "TRUE", "disable-legacy-endpoints": "TRUE", "serial-port-enable": "FALSE", "startup-script": "", "startup-script-url": ""} {
		if metadata[key] != value {
			return errors.New("recovery host metadata boundary changed")
		}
	}
	if fmt.Sprintf("%x", sha256.Sum256([]byte(metadata["user-data"]))) != target.UserDataSHA256 {
		return errors.New("recovery host definition changed")
	}
	if len(vm.Disks) != 2 || vm.Disks[0].Boot == vm.Disks[1].Boot {
		return errors.New("recovery host disk attachments changed")
	}
	for _, disk := range vm.Disks {
		if disk.Boot {
			if !disk.AutoDelete || disk.DeviceName == diskName {
				return errors.New("invalid recovery boot disk")
			}
		} else if disk.AutoDelete || disk.DeviceName != diskName || disk.Source != zonal+"disks/"+diskName || disk.Mode != "READ_WRITE" {
			return errors.New("invalid recovery data disk attachment")
		}
	}
	data, err = host.cloud(ctx, "disks", "describe", diskName, "--format=json")
	var disk compute.Disk
	if err != nil || json.Unmarshal(data, &disk) != nil || strconv.FormatUint(disk.Id, 10) != target.DiskID ||
		disk.Name != diskName || disk.SizeGb != int64(host.DiskGiB) || disk.Type != zonal+"diskTypes/pd-ssd" ||
		!slices.Equal(disk.Users, []string{zonal + "instances/" + hostName}) {
		return errors.New("recovery disk incarnation or ownership changed")
	}
	if disk.SourceImage != "" || disk.SourceSnapshot != "" || disk.SourceDisk != "" {
		return errors.New("recovery disk was not created empty")
	}
	return nil
}

func (host Host) prepareDisk(ctx context.Context) error {
	data, err := host.ssh(ctx, "sudo -n lsblk --json --bytes --output TYPE,SIZE,FSTYPE,MOUNTPOINTS "+diskPath)
	var block struct {
		Devices []struct {
			Type        string
			Size        json.Number
			FSType      *string
			Mountpoints []*string
			Children    []json.RawMessage
		} `json:"blockdevices"`
	}
	if err != nil || json.Unmarshal(data, &block) != nil || len(block.Devices) != 1 {
		return errors.New("recovery disk observation unavailable")
	}
	disk := block.Devices[0]
	if disk.Type != "disk" || disk.Size.String() != strconv.FormatInt(int64(host.DiskGiB)<<30, 10) ||
		disk.FSType != nil || len(disk.Children) != 0 || slices.ContainsFunc(disk.Mountpoints, func(path *string) bool { return path != nil }) {
		return errors.New("recovery disk is not blank and unmounted")
	}
	data, err = host.ssh(ctx, "sudo -n wipefs --no-act --json --output TYPE "+diskPath)
	var signatures struct {
		Signatures *[]json.RawMessage `json:"signatures"`
	}
	if err != nil || json.Unmarshal(data, &signatures) != nil || signatures.Signatures == nil || len(*signatures.Signatures) != 0 {
		return errors.New("recovery disk has signatures or could not be inspected")
	}
	// mkdir is exclusive; mkfs has no force flag. Neither accepts a caller-supplied path.
	for _, command := range []string{
		"sudo -n mkdir -p /mnt/disks",
		"sudo -n mkdir -m 0700 " + mountPath,
		"sudo -n mkfs.ext4 -m 0 -L agora-recovery " + diskPath,
		"sudo -n mount -t ext4 -o discard,nodev,nosuid,noexec " + diskPath + " " + mountPath,
	} {
		if _, err := host.ssh(ctx, command); err != nil {
			return err
		}
	}
	return nil
}

func (host Host) cloud(ctx context.Context, args ...string) ([]byte, error) {
	var output bytes.Buffer
	args = append(append([]string{"compute"}, args...), "--quiet", "--project="+host.Target.Project, "--zone="+host.Target.Zone)
	err := host.Execute(ctx, &output, "gcloud", args...)
	if err != nil || output.Len() > 1<<20 {
		return nil, errors.New("native recovery command failed; retain guard and inspect without replay")
	}
	return output.Bytes(), nil
}

func (host Host) ssh(ctx context.Context, command string) ([]byte, error) {
	return host.cloud(ctx, "ssh", hostName, "--tunnel-through-iap", "--ssh-key-expire-after=1h",
		"--ssh-key-file="+filepath.Join(host.Scratch, "recovery-key"), "--ssh-flag=-oConnectTimeout=10", "--ssh-flag=-oConnectionAttempts=12", "--command="+command)
}
