package tests_test

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"slices"
	"strings"
	"testing"
	"testing/synctest"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/a-novel/infra/internal/recovery"
)

type recoveryHostFixture struct {
	host     recovery.Host
	vm, disk object
	replies  map[string]string
	commands []string
	fail     string
}

const recoveryBootProbe = "sudo -n systemctl is-active cloud-init-local.service cloud-init.service cloud-config.service cloud-final.service"

func newRecoveryHost(t *testing.T, request recovery.Request) *recoveryHostFixture {
	t.Helper()
	base := "https://www.googleapis.com/compute/v1/projects/" + request.Project + "/"
	zonal := base + "zones/europe-west1-d/"
	const name = "agora-native-recovery"
	metadata := []object{}
	for key, value := range map[string]string{"enable-oslogin": "TRUE", "block-project-ssh-keys": "TRUE", "disable-legacy-endpoints": "TRUE", "serial-port-enable": "FALSE", "user-data": "prepared"} {
		metadata = append(metadata, object{"key": key, "value": value})
	}
	requestJSON, err := json.Marshal(request)
	require.NoError(t, err)
	f := &recoveryHostFixture{
		vm: object{
			"id": "1001", "name": name, "status": "TERMINATED", "zone": strings.TrimSuffix(zonal, "/"), "machineType": zonal + "machineTypes/e2-medium",
			"serviceAccounts":        []object{{"email": request.Identity(), "scopes": []string{"https://www.googleapis.com/auth/cloud-platform"}}},
			"networkInterfaces":      []object{{"network": base + "global/networks/" + name, "subnetwork": base + "regions/europe-west1/subnetworks/" + name}},
			"scheduling":             object{"automaticRestart": false, "maxRunDuration": object{"seconds": "14400"}, "instanceTerminationAction": "STOP"},
			"metadata":               object{"items": metadata},
			"shieldedInstanceConfig": object{"enableSecureBoot": true, "enableVtpm": true, "enableIntegrityMonitoring": true},
			"disks":                  []object{{"boot": true, "autoDelete": true}, {"deviceName": name + "-data", "source": zonal + "disks/" + name + "-data", "mode": "READ_WRITE"}},
		},
		disk: object{"id": "1002", "name": name + "-data", "sizeGb": "10", "type": zonal + "diskTypes/pd-ssd", "users": []string{zonal + "instances/" + name}},
		replies: map[string]string{
			recoveryBootProbe: "active\nactive\nactive\nactive\n",
			"sudo -n cat /etc/agora-recovery/request.json": string(requestJSON),
			"sudo -n lsblk --json --bytes --output TYPE,SIZE,FSTYPE,MOUNTPOINTS /dev/disk/by-id/google-agora-native-recovery-data": `{"blockdevices":[{"type":"disk","size":10737418240,"fstype":null,"mountpoints":[null]}]}`,
			"sudo -n wipefs --no-act --json --output TYPE /dev/disk/by-id/google-agora-native-recovery-data":                       `{"signatures":[]}`,
			"sudo -n cat /mnt/disks/agora-recovery/work/attempt/request.json":                                                      string(requestJSON),
			"sudo -n cat /mnt/disks/agora-recovery/work/attempt/catalog.json":                                                      fmt.Sprintf(`[{"name":"json-keys","status":{"code":0},"db":[{"id":1,"repo-key":1,"system-id":%s,"version":"18"}],"backup":[{"label":%q,"error":false,"database":{"id":1,"repo-key":1}}]}]`, request.SystemID, request.Set),
			"sudo -n cat /mnt/disks/agora-recovery/work/attempt/restore.log":                                                       privateValue,
			"sudo -n cat /mnt/disks/agora-recovery/work/attempt/files-restored.json":                                               fmt.Sprintf(`{"system_id":%q,"set":%q,"postgresql_started":false}`, request.SystemID, request.Set),
		},
	}
	f.host = recovery.Host{
		Target: recovery.Target{Project: request.Project, Zone: "europe-west1-d", Host: name, Disk: name + "-data", InstanceID: "1001", DiskID: "1002", UserDataSHA256: fmt.Sprintf("%x", sha256.Sum256([]byte("prepared"))), Request: request}, DiskGiB: 10,
		Image: "europe-west1-docker.pkg.dev/" + request.Project + "/agora-tooling/native-restore@sha256:" + strings.Repeat("a", 64), Scratch: t.TempDir(), Execute: f.execute,
	}
	return f
}

func (f *recoveryHostFixture) execute(_ context.Context, output io.Writer, binary string, args ...string) error {
	if binary != "gcloud" {
		return errors.New("unexpected binary")
	}
	command := ""
	for _, arg := range args {
		if value, ok := strings.CutPrefix(arg, "--command="); ok {
			command = value
		}
	}
	if command == "" {
		command = strings.Join(args[1:len(args)-3], " ")
	}
	f.commands = append(f.commands, command)
	if f.fail != "" && strings.Contains(command, f.fail) {
		return errors.New(privateValue)
	}
	if strings.HasPrefix(command, "instances describe") {
		return json.NewEncoder(output).Encode(f.vm)
	}
	if strings.HasPrefix(command, "disks describe") {
		return json.NewEncoder(output).Encode(f.disk)
	}
	if strings.HasPrefix(command, "instances start") {
		f.vm["status"] = "RUNNING"
	}
	if strings.HasPrefix(command, "instances stop") {
		f.vm["status"] = "TERMINATED"
	}
	if strings.HasPrefix(command, "sudo -n docker inspect") {
		network := "bridge"
		if strings.HasSuffix(command, "agora-native-verify") {
			network = "none"
			if f.fail == "verify-network" {
				network = "bridge"
			}
		}
		_, err := fmt.Fprint(output, "exited|0|"+f.host.Image+"|no|"+network)
		return err
	}
	_, err := fmt.Fprint(output, f.replies[command])
	return err
}

func TestNativeRecoveryHost(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name, fault   string
		format, start bool
	}{
		{"Success", "", true, true},
		{"ReplacedVM", "vm", false, false},
		{"ReplacedDisk", "disk", false, false},
		{"RunningVM", "running", false, false},
		{"WrongIdentity", "identity", false, false},
		{"PublicHost", "public", false, false},
		{"UnboundedRuntime", "uncapped", false, false},
		{"Signature", "signature", false, false},
		{"UsedDisk", "used", false, false},
		{"MountedDisk", "mounted", false, false},
		{"ExistingMount", "mkdir", false, false},
		{"UncertainWorker", "systemctl start", true, true},
		{"MissingEvidence", "files-restored.json", true, true},
		{"UncertainStop", "instances stop", true, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			f := setup(t)
			inputs, err := json.Marshal(nativeInputs(t, f))
			require.NoError(t, err)
			var config struct{ Recovery recovery.Request }
			require.NoError(t, json.Unmarshal(inputs, &config))
			config.Recovery.Service, config.Recovery.Major = "json-keys", 18
			h := newRecoveryHost(t, config.Recovery)
			h.host.Execute = func(ctx context.Context, output io.Writer, binary string, args ...string) error {
				if len(args) > 1 && args[1] == "ssh" {
					require.Contains(t, args, "--billing-project="+config.Recovery.Project)
				}
				return h.execute(ctx, output, binary, args...)
			}
			switch tc.fault {
			case "vm":
				h.vm["id"] = "1003"
			case "disk":
				h.disk["id"] = "1003"
			case "running":
				h.vm["status"] = "RUNNING"
			case "identity":
				h.vm["serviceAccounts"] = []object{{"email": "writer@example.com"}}
			case "public":
				h.vm["networkInterfaces"].([]object)[0]["accessConfigs"] = []object{{"natIP": "203.0.113.1"}}
			case "uncapped":
				delete(h.vm["scheduling"].(object), "maxRunDuration")
			case "signature":
				for command := range h.replies {
					if strings.Contains(command, "wipefs") {
						h.replies[command] = `{"signatures":[{"type":"ext4"}]}`
					}
				}
			case "used", "mounted":
				for command, reply := range h.replies {
					if strings.Contains(command, "lsblk") {
						if tc.fault == "used" {
							reply = strings.ReplaceAll(reply, `"fstype":null`, `"fstype":"ext4"`)
						} else {
							reply = strings.ReplaceAll(reply, `[null]`, `["/data"]`)
						}
						h.replies[command] = reply
					}
				}
			default:
				h.fail = tc.fault
			}
			files, err := h.host.Restore(t.Context())
			for _, once := range []string{"instances start", "mkfs.ext4", "systemctl start agora-native-restore"} {
				calls := 0
				for _, command := range h.commands {
					if strings.Contains(command, once) {
						calls++
					}
				}
				require.LessOrEqual(t, calls, 1)
			}
			contains := func(value string) bool {
				return slices.ContainsFunc(h.commands, func(command string) bool { return strings.Contains(command, value) })
			}
			require.Equal(t, []bool{tc.fault == "", tc.format, tc.start}, []bool{err == nil, contains("mkfs.ext4"), contains("systemctl start")})
			if err == nil {
				require.NoError(t, config.Recovery.CheckFiles(files))
				require.Equal(t, "TERMINATED", h.vm["status"])
			} else {
				require.Nil(t, files)
			}
		})
	}
}

func TestNativeRecoveryHostReadiness(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name       string
		readyAfter int
		cancel     bool
		blocked    bool
		unready    string
		degraded   bool
		elapsed    time.Duration
		err        error
	}{
		{name: "Success", readyAfter: 1},
		{name: "Success/DelayedSSH", readyAfter: 3, elapsed: 10 * time.Second},
		{name: "Success/DelayedInitialization", readyAfter: 3, unready: "active\nactive\nactive\nactivating\n", elapsed: 10 * time.Second},
		{name: "Success/DegradedCloudInitStatus", readyAfter: 1, degraded: true},
		{name: "Error/FailedInitialization", unready: "active\nactive\nactive\nfailed\n", elapsed: 2 * time.Minute, err: context.DeadlineExceeded},
		{name: "Error/SkippedInitialization", unready: "inactive\ninactive\ninactive\ninactive\n", elapsed: 2 * time.Minute, err: context.DeadlineExceeded},
		{name: "Error/IncompleteObservation", unready: "active\n", elapsed: 2 * time.Minute, err: context.DeadlineExceeded},
		{name: "Error/Unavailable", elapsed: 2 * time.Minute, err: context.DeadlineExceeded},
		{name: "Error/Cancelled", cancel: true, err: context.Canceled},
		{name: "Error/BlockedProbe", blocked: true, elapsed: 2 * time.Minute, err: context.DeadlineExceeded},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			synctest.Test(t, func(t *testing.T) {
				f := setup(t)
				inputs, err := json.Marshal(nativeInputs(t, f))
				require.NoError(t, err)
				var config struct{ Recovery recovery.Request }
				require.NoError(t, json.Unmarshal(inputs, &config))
				config.Recovery.Service, config.Recovery.Major = "json-keys", 18
				h := newRecoveryHost(t, config.Recovery)
				if tc.degraded {
					h.fail = "cloud-init status"
				}
				ctx, cancel := context.WithCancel(t.Context())
				defer cancel()
				probes := 0
				h.host.Execute = func(probeCtx context.Context, output io.Writer, binary string, args ...string) error {
					if slices.Contains(args, "--command="+recoveryBootProbe) {
						probes++
						if tc.cancel {
							cancel()
						}
						if tc.blocked {
							<-probeCtx.Done()
						}
						if probes != tc.readyAfter {
							if tc.unready != "" {
								_, err := fmt.Fprint(output, tc.unready)
								return err
							}
							return errors.New(privateValue)
						}
					}
					return h.execute(probeCtx, output, binary, args...)
				}
				started := time.Now()
				files, err := h.host.Restore(ctx)
				require.Equal(t, tc.elapsed, time.Since(started))
				if tc.err == nil {
					require.NoError(t, err)
					require.Equal(t, tc.readyAfter, probes)
					require.NoError(t, config.Recovery.CheckFiles(files))
				} else {
					require.ErrorIs(t, err, tc.err)
					require.NotContains(t, err.Error(), privateValue)
					require.Nil(t, files)
					require.False(t, slices.ContainsFunc(h.commands, func(command string) bool {
						return strings.Contains(command, "cloud-init status") || strings.Contains(command, "mkfs") || strings.Contains(command, "systemctl start")
					}))
					// The final poll and context deadline can become runnable together.
					require.LessOrEqual(t, probes, 25)
				}
			})
		})
	}
}
