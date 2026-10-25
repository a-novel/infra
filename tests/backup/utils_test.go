package backup_test

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/a-novel/infra/internal/recovery"
)

// proof is one synthetic PostgreSQL cluster under root, archiving to a local pgBackRest repository
// through stanza.
type proof struct{ root, config, source, repo, stanza string }

// newProof creates only synthetic data, shared by the local and TLS transport cases. The image's
// init.sql initializes database, which pg_cron serves, as on the service's database host.
func newProof(t *testing.T, stanza, database string) proof {
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
	// The settings follow the image's own, such as genai's preloaded pg_cron.
	conf, err := os.OpenFile(filepath.Join(p.source, "postgresql.conf"), os.O_APPEND|os.O_WRONLY, 0)
	require.NoError(t, err)
	_, err = fmt.Fprintf(conf, `listen_addresses=''
unix_socket_directories='%s'
shared_buffers='64MB'
max_connections=20
wal_level=replica
archive_mode=on
archive_command='pgbackrest --config=%s --stanza=%s archive-push %%p'
cron.database_name='%s'
`, p.root, p.config, stanza, database)
	require.NoError(t, errors.Join(err, conf.Close()))
	p.start(t, p.source, p.root)
	p.backrest(t, "stanza-create")
	if database != "postgres" {
		p.query(t, "postgres", "CREATE DATABASE "+database+";")
	}
	run(t, "psql", "-X", "-h", p.root, "-d", database, "-v", "ON_ERROR_STOP=1", "-f", "/docker-entrypoint-initdb.d/init.sql")
	p.query(t, "postgres", `CREATE ROLE proof_reader;
CREATE TABLE sample (id uuid PRIMARY KEY, value text NOT NULL CHECK (value <> ''));
INSERT INTO sample VALUES ('00000000-0000-0000-0000-000000000001', 'original');`)
	return p
}

// backup is one backup set in pgBackRest's JSON info.
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

// localCommand runs native tools as production does, with pgBackRest reading the proof's local
// repository instead of Cloud Storage. Every selection, identity check and restore option stays real.
func (p proof) localCommand(t *testing.T) recovery.Executor {
	return func(ctx context.Context, diagnostics io.Writer, binary string, args ...string) ([]byte, error) {
		if binary == "/usr/bin/pgbackrest" {
			local := []string{"--repo1-type=posix", "--repo1-path=" + p.repo}
			for _, arg := range args {
				if !strings.HasPrefix(arg, "--repo1-") {
					local = append(local, arg)
				}
			}
			args = local
		}
		output, err := recovery.Command(ctx, diagnostics, binary, args...)
		if err != nil {
			t.Logf("synthetic native diagnostics: %s", output)
		}
		return output, err
	}
}

// psql returns a command that runs statement in database as the cluster's superuser, reading it
// from standard input.
func (p proof) psql(t *testing.T, database, statement string, args ...string) *exec.Cmd {
	t.Helper()
	cmd := exec.CommandContext(t.Context(), "psql", append([]string{"-XqAt", "-h", p.root, "-d", database, "-v", "ON_ERROR_STOP=1"}, args...)...)
	cmd.Stdin = strings.NewReader(statement)
	return cmd
}

// query runs statement in database and returns its trimmed standard output, failing the test on an
// error. Warnings, such as a collation version mismatch, stay out of the result.
func (p proof) query(t *testing.T, database, statement string) string {
	t.Helper()
	var diagnostics strings.Builder
	cmd := p.psql(t, database, statement)
	cmd.Stderr = &diagnostics
	out, err := cmd.Output()
	require.NoError(t, err, diagnostics.String())
	return strings.TrimSpace(string(out))
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
