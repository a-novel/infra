package tests_test

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestNativeMaintenanceIAMBoundary(t *testing.T) {
	t.Parallel()
	// The live address is unknown in a cold mock plan; check the expression's
	// ownership here while the HCL test covers enrollment and principal selection.
	config := read(t, "../environments/production/foundation/maintenance.tf")
	resource, _, ok := strings.Cut(config, `variable "legacy_backup_job_access"`)
	require.True(t, ok)
	require.Contains(t, resource, `expression  = "destination.port == 22 && destination.ip == '${one(data.google_compute_instance.database[replace(each.key, "-", "_")].network_interface).network_ip}'"`)
}

// TestNativeBackup exercises the actual host script with no cloud clients or Docker available.
func TestNativeBackup(t *testing.T) {
	t.Parallel()
	for _, scenario := range []string{"Success", "WrongHost", "WrongImage", "Busy", "WorkerFailure", "ContainerFailure", "BadIdentity"} {
		t.Run(scenario, func(t *testing.T) {
			t.Parallel()
			f := setup(t)
			f.env["SCENARIO"] = scenario
			code, out := f.run(t, "bash", "-c", `
id() { printf 0; }
curl() { if [ "$SCENARIO" = WrongHost ]; then printf 334; else printf 333; fi; }
systemctl() {
    case "$1" in
        is-active) return 0 ;;
        start) printf '%s\n' "$3" >> "$TMPDIR/workers"; test "$SCENARIO" != WorkerFailure ;;
        show)
            case "$3" in
                --property=ActiveState) if [ "$SCENARIO" = Busy ]; then printf active; else printf inactive; fi ;;
                --property=Result) printf success ;;
                --property=ExecMainStatus) printf 0 ;;
                *) return 90 ;;
            esac ;;
        *) return 90 ;;
    esac
}
docker() {
    case "$1" in
        inspect)
            if [[ "$*" == *Config.Image* ]]; then
                if [ "$SCENARIO" = WrongImage ]; then printf wrong; else printf 'image@sha256:%064d' 0; fi
            elif [ "$SCENARIO" = ContainerFailure ]; then printf 1; else printf 0; fi ;;
        exec)
            if [[ "$*" == *pg_control_system* ]]; then
                if [ "$SCENARIO" = BadIdentity ]; then printf invalid; else printf 7685450249510117419; fi
            else printf '[]'; fi ;;
        *) return 90 ;;
    esac
}
set -- json-keys 333 "$(printf '%064d' 0)"
. internal/database/nativeBackup.sh
`)
			if scenario == "Success" {
				expectCode(t, 0, code, out)
				require.Equal(t, "7685450249510117419\n[]", out)
				require.Equal(t, "agora-backup-check.service\nagora-backup-full.service\n", read(t, filepath.Join(f.dir, "workers")))
			} else {
				require.NotZero(t, code)
				if scenario != "WorkerFailure" && scenario != "ContainerFailure" {
					require.NoFileExists(t, filepath.Join(f.dir, "workers"))
				}
			}
		})
	}
}

// TestNativeRestore checks isolation, bounded scratch use and failure cleanup of the repository adapter.
func TestNativeRestore(t *testing.T) {
	t.Parallel()
	for _, scenario := range []string{"Success", "LowSpace", "WrongHost", "WrongImage", "RestoreFailure", "SQLFailure", "ExistingContainer"} {
		t.Run(scenario, func(t *testing.T) {
			t.Parallel()
			f := setup(t)
			f.env["SCENARIO"] = scenario
			for _, name := range []string{"base64", "tail"} {
				path, err := exec.LookPath(name)
				require.NoError(t, err)
				f.link(t, name, path)
			}
			// Redirect the host-specific scratch root before executing any shell code.
			script := strings.ReplaceAll(read(t, filepath.Join(f.root, "internal/database/nativeRestore.sh")), "/mnt/stateful_partition", f.dir)
			path := filepath.Join(f.dir, "restore.sh")
			require.NoError(t, os.WriteFile(path, []byte(script), 0o600))
			code, out := f.run(t, "bash", "-c", `
id() { printf 0; }
curl() { if [ "$SCENARIO" = WrongHost ]; then printf 334; else printf 333; fi; }
systemctl() { return 0; }
df() { if [ "$SCENARIO" = LowSpace ]; then printf 1; else printf 21474836480; fi; }
install() { mkdir -p "$8" "$9"; }
chown() { return 0; }
realpath() { printf '%s' "$1"; }
docker() {
    printf '%s\n' "$*" >> "$TMPDIR/docker-calls"
    case "$1" in
        container) test "$SCENARIO" = ExistingContainer || test -e "$TMPDIR/$3" ;;
        inspect)
            case "$*" in
                *Config.Image*) if [ "$SCENARIO" = WrongImage ]; then printf wrong; else printf 'image@sha256:%064d' 0; fi ;;
                *ExitCode*) printf 0 ;;
                *NetworkMode*) printf none ;;
                *Running*) printf false ;;
                *) return 90 ;;
            esac ;;
        run)
            name="${2#--name=}"
            printf stopped > "$TMPDIR/$name"
            if [[ "$name" == *-restore-* && "$SCENARIO" = RestoreFailure ]] || [[ "$name" == *-sql-* && "$SCENARIO" = SQLFailure ]]; then return 1; fi ;;
        stop) printf stopped > "$TMPDIR/$3" ;;
        rm) shift; for name in "$@"; do rm "$TMPDIR/$name"; done ;;
        *) return 90 ;;
    esac
}
set -- authentication 333 20261007-041158F 7685450634703327274 "$(printf '%064d' 0)" 67108864 U0VMRUNUIHRydWU7
. "$TMPDIR/restore.sh"
`)
			scratch := filepath.Join(f.dir, "agora-maintenance-proof-authentication-20261007-041158F")
			if scenario == "Success" {
				expectCode(t, 0, code, out)
				require.Equal(t, "sql-verified:7685450634703327274:20261007-041158F\n", out)
				require.NoDirExists(t, scratch)
				calls := read(t, filepath.Join(f.dir, "docker-calls"))
				require.Contains(t, calls, "--network=host")
				require.Contains(t, calls, "--network=none")
				require.NotContains(t, calls, "/mnt/disks/agora-data")
				require.NotContains(t, calls, "--force")
				require.NoFileExists(t, filepath.Join(f.dir, "agora-maintenance-sql-authentication"))
			} else {
				require.NotZero(t, code, out)
				if scenario == "RestoreFailure" || scenario == "SQLFailure" {
					require.DirExists(t, scratch)
					require.Equal(t, "stopped", read(t, filepath.Join(f.dir, "agora-maintenance-restore-authentication")))
					require.Contains(t, read(t, filepath.Join(f.dir, "docker-calls")), "stop --time=30 agora-maintenance-restore-authentication")
				} else {
					require.NoDirExists(t, scratch)
				}
			}
		})
	}
}
