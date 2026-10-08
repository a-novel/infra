package backup_test

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

type proof struct{ root, config, source, repo, stanza string }

// newProof creates only synthetic data, shared by the local and TLS transport cases.
func newProof(t *testing.T, stanza string) proof {
	t.Helper()
	p := proof{root: t.TempDir(), stanza: stanza}
	p.config = filepath.Join(p.root, "pgbackrest.conf")
	p.source = filepath.Join(p.root, "source")
	p.repo = filepath.Join(p.root, "repository")
	write(t, p.config, fmt.Sprintf(`[global]
repo1-path=%s
repo1-retention-full=2
process-max=1
start-fast=y
archive-timeout=10
db-timeout=15
protocol-timeout=30
log-level-console=warn
log-level-file=off
lock-path=%s/lock

[%s]
pg1-path=%s
pg1-socket-path=%s
`, p.repo, p.root, stanza, p.source, p.root))
	run(t, "initdb", "-D", p.source, "--auth-local=peer", "--auth-host=scram-sha-256", "--no-locale")
	write(t, filepath.Join(p.source, "postgresql.conf"), fmt.Sprintf(`listen_addresses=''
unix_socket_directories='%s'
shared_buffers='64MB'
max_connections=20
wal_level=replica
archive_mode=on
archive_command='pgbackrest --config=%s --stanza=%s archive-push %%p'
`, p.root, p.config, stanza))
	p.start(t, p.source, p.root)
	p.backrest(t, "stanza-create")
	run(t, "psql", "-X", "-h", p.root, "-d", "postgres", "-v", "ON_ERROR_STOP=1", "-f", "/docker-entrypoint-initdb.d/init.sql")
	p.sql(t, `CREATE ROLE proof_reader;
CREATE TABLE sample (id uuid PRIMARY KEY, value text NOT NULL CHECK (value <> ''));
INSERT INTO sample VALUES ('00000000-0000-0000-0000-000000000001', 'original');`)
	return p
}

type backup struct {
	Label   string
	Archive struct{ Start string }
}

func (p proof) command(ctx context.Context, args ...string) *exec.Cmd {
	return exec.CommandContext(ctx, "pgbackrest", append([]string{"--config=" + p.config, "--stanza=" + p.stanza}, args...)...)
}

func (p proof) backrest(t *testing.T, args ...string) string {
	t.Helper()
	start := time.Now()
	cmd := p.command(t.Context(), args...)
	cmd.Stderr = os.Stderr
	out, err := cmd.Output()
	require.NoError(t, err, "pgbackrest %v: %s", args, out)
	t.Logf("pgbackrest %v: %s", args, time.Since(start).Round(time.Millisecond))
	return string(out)
}

func (p proof) backups(t *testing.T) []backup {
	t.Helper()
	var info []struct{ Backup []backup }
	out := p.backrest(t, "--output=json", "info")
	require.NoError(t, json.Unmarshal([]byte(out), &info), "%s", out)
	require.Len(t, info, 1)
	return info[0].Backup
}

func (p proof) sql(t *testing.T, sql string) string {
	t.Helper()
	return run(t, "psql", "-XAt", "-h", p.root, "-d", "postgres", "-v", "ON_ERROR_STOP=1", "-c", sql)
}

func (p proof) start(t *testing.T, data, socket string) {
	t.Helper()
	out, err := p.boot(t, data, socket)
	require.NoError(t, err, "%s", out)
}

func (p proof) boot(t *testing.T, data, socket string) ([]byte, error) {
	t.Helper()
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		_ = exec.CommandContext(ctx, "pg_ctl", "-D", data, "-m", "immediate", "stop").Run()
	})
	// Startup logs use a file: pg_ctl must not leave the server holding Go's output pipe.
	return exec.CommandContext(t.Context(), "pg_ctl", "-D", data, "-l", data+".log", "-o", "-k "+socket, "-t", "15", "-w", "start").CombinedOutput()
}

func (p proof) stop(t *testing.T, data string) {
	t.Helper()
	run(t, "pg_ctl", "-D", data, "-m", "fast", "-w", "stop")
}

func (p proof) restore(t *testing.T, label, want string, options ...string) {
	t.Helper()
	start := time.Now()
	data := filepath.Join(t.TempDir(), "restore")
	if len(options) == 0 {
		options = []string{"--type=immediate"}
	}
	args := append([]string{"--set=" + label, "--pg1-path=" + data, "--target-action=promote", "--archive-mode=off"}, options...)
	p.backrest(t, append(args, "restore")...)
	// Isolate restored sockets from the still-running source.
	p.start(t, data, filepath.Dir(data))
	// A standby can accept read-only SQL before reaching the requested recovery target.
	require.Eventually(t, func() bool {
		out, err := exec.CommandContext(t.Context(), "psql", "-XAt", "-h", filepath.Dir(data), "-d", "postgres", "-c", "SELECT pg_is_in_recovery();").Output()
		return err == nil && strings.TrimSpace(string(out)) == "f"
	}, 20*time.Second, 100*time.Millisecond, "recovery target was not promoted")
	got := run(t, "psql", "-XAt", "-h", filepath.Dir(data), "-d", "postgres", "-v", "ON_ERROR_STOP=1", "-c", `SELECT value FROM sample;
SELECT count(*) FROM pg_roles WHERE rolname = 'proof_reader';
SELECT uuid_generate_v4() IS NOT NULL;`)
	require.Equal(t, want+"\n1\nt", strings.TrimSpace(got))
	t.Logf("restore through SQL verification: %s", time.Since(start).Round(time.Millisecond))
	p.stop(t, data)
}

func run(t *testing.T, binary string, args ...string) string {
	t.Helper()
	out, err := exec.CommandContext(t.Context(), binary, args...).CombinedOutput()
	require.NoError(t, err, "%s %v: %s", binary, args, out)
	return string(out)
}

func write(t *testing.T, path, value string) {
	t.Helper()
	require.NoError(t, os.WriteFile(path, []byte(value), 0o600))
}
