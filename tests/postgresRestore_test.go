package tests_test

import (
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func TestPostgresRestoreStartup(t *testing.T) {
	t.Parallel()
	for _, scenario := range []string{"ready", "crash", "missing-pid", "unready"} {
		t.Run(scenario, func(t *testing.T) {
			t.Parallel()
			f := setup(t)
			for _, name := range []string{"head", "sleep"} {
				path, err := exec.LookPath(name)
				require.NoError(t, err)
				f.link(t, name, path)
			}
			for _, name := range []string{"install", "gosu", "pg_isready", "entrypoint"} {
				f.command(t, name)
			}
			f.env["RESTORE_SCENARIO"], f.env["PGDATA"], f.env["WORKSPACE"] = scenario, filepath.Join(f.dir, "pgdata"), f.dir
			f.env["PGSOCKET"], f.env["DATABASE_NAME"], f.env["DATABASE_OWNER"] = filepath.Join(f.dir, "socket"), "fixture", "postgres"
			restore := read(t, filepath.Join(f.root, "environments/production/release/scripts/postgres-restore.sh"))
			fragment := func(start, end string) string {
				_, remainder, found := strings.Cut(restore, start)
				require.True(t, found)
				body, _, found := strings.Cut(remainder, end)
				require.True(t, found)
				return start + body
			}
			// Execute the real traps and startup loop without mounting backups or starting PostgreSQL.
			startup := strings.ReplaceAll(fragment("install -d -m 0700", "export PGDATABASE="), "/usr/local/bin/docker-entrypoint.sh", "entrypoint")
			startup = strings.ReplaceAll(startup, "SECONDS + 120", "SECONDS + 3")
			harness := `set -euo pipefail
POSTGRES_PID=""
kill() {
    if [ "$1" != -0 ]; then printf 'stop-entrypoint\n' >>"$TMPDIR/calls"; fi
    builtin kill "$@"
}
` + fragment("cleanup() {", "for variable_name") + startup + `printf 'restore-ready\n' >>"$TMPDIR/calls"`
			code, out := f.run(t, "bash", "-c", harness)
			events := ""
			if _, err := os.Stat(filepath.Join(f.dir, "calls")); err == nil {
				events = read(t, filepath.Join(f.dir, "calls"))
			}
			require.NotContains(t, events, "probe-temporary")
			if scenario == "ready" {
				expectCode(t, 0, code, out)
				require.Equal(t, "probe-final\nrestore-ready\nstop-entrypoint\nstop-server\n", events)
			} else {
				expectCode(t, 1, code, out)
				require.Contains(t, out, "clean restore database did not become ready")
				require.NotContains(t, events, "restore-ready")
				if scenario != "crash" {
					require.True(t, strings.HasSuffix(events, "stop-entrypoint\nstop-server\n"), "%s", events)
				}
			}
		})
	}
}

// restoreCommand models only startup identity and readiness; the helper exits on
// the real cleanup signal and has a deadline if a broken trap leaves it running.
func restoreCommand(name string, args []string) (int, error) {
	data, scenario := os.Getenv("PGDATA"), os.Getenv("RESTORE_SCENARIO")
	switch {
	case name == "install" && slices.Equal(args, []string{"-d", "-m", "0700", "-o", "postgres", "-g", "postgres", data}):
		return 0, os.Mkdir(data, 0o700)
	case name == "gosu" && slices.Equal(args, []string{"postgres", "pg_ctl", "--pgdata=" + data, "--mode=fast", "--wait", "stop"}):
		return 0, record("stop-server")
	case name == "pg_isready" && slices.Equal(args, []string{"--host=" + os.Getenv("PGSOCKET"), "--port=5432", "--username=postgres", "--dbname=fixture"}):
		pid, err := os.ReadFile(filepath.Join(data, "postmaster.pid"))
		if err != nil || string(pid) == "0\n" {
			return 0, record("probe-temporary")
		}
		code := 0
		if scenario == "unready" {
			code = 1
		}
		return code, record("probe-final")
	case name == "entrypoint" && slices.Equal(args, []string{"postgres", "-c", "listen_addresses=", "-c", "log_min_messages=panic", "-c", "log_min_error_statement=panic"}):
		if scenario == "crash" {
			return 9, nil
		}
		stopped := make(chan os.Signal, 1)
		signal.Notify(stopped, syscall.SIGTERM, os.Interrupt)
		defer signal.Stop(stopped)
		if scenario != "missing-pid" {
			pid := filepath.Join(data, "postmaster.pid")
			if err := os.WriteFile(pid, []byte("0\n"), 0o600); err != nil {
				return 99, err
			}
			time.Sleep(200 * time.Millisecond)
			if err := os.WriteFile(pid, []byte(strconv.Itoa(os.Getpid())+"\n"), 0o600); err != nil {
				return 99, err
			}
		}
		select {
		case <-stopped:
			return 0, nil
		case <-time.After(10 * time.Second):
			return 99, fmt.Errorf("restore fixture was not stopped")
		}
	default:
		return 99, fmt.Errorf("unexpected restore command: %s %v", name, args)
	}
}
