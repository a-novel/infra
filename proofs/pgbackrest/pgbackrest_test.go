package pgbackrest_test

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

// TestRecovery exercises installed PostgreSQL/pgBackRest, never a cloud repository.
// Cases are sequential because they evolve one synthetic cluster and backup chain.
func TestRecovery(t *testing.T) {
	if os.Getenv("INFRA_PGBACKREST_PROOF") != "1" {
		t.Skip("run the disposable pgbackrest-proof image; see README.md")
	}
	t.Log(strings.TrimSpace(run(t, "pgbackrest", "version")))
	t.Log(strings.TrimSpace(run(t, "postgres", "--version")))
	t.Log(strings.TrimSpace(run(t, "/usr/lib/postgresql/17/bin/postgres", "--version")))
	p := proof{root: t.TempDir()}
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

[proof]
pg1-path=%s
pg1-socket-path=%s
`, p.repo, p.root, p.source, p.root))
	run(t, "initdb", "-D", p.source, "--auth-local=peer", "--auth-host=scram-sha-256", "--no-locale")
	write(t, filepath.Join(p.source, "postgresql.conf"), fmt.Sprintf(`listen_addresses=''
unix_socket_directories='%s'
shared_buffers='64MB'
max_connections=20
wal_level=replica
archive_mode=on
archive_command='pgbackrest --config=%s --stanza=proof archive-push %%p'
`, p.root, p.config))
	p.start(t, p.source, p.root)
	p.backrest(t, "stanza-create")
	run(t, "psql", "-X", "-h", p.root, "-d", "postgres", "-v", "ON_ERROR_STOP=1", "-f", "/docker-entrypoint-initdb.d/init.sql")
	p.sql(t, `CREATE ROLE proof_reader;
CREATE TABLE sample (id uuid PRIMARY KEY, value text NOT NULL CHECK (value <> ''));
INSERT INTO sample VALUES ('00000000-0000-0000-0000-000000000001', 'original');`)
	var first, retained, newest backup
	for _, tc := range []struct {
		name string
		run  func(*testing.T)
	}{
		{"full backup and clean restore", func(t *testing.T) {
			p.backrest(t, "--type=full", "backup")
			first = p.backups(t)[0]
			p.restore(t, first.Label, "original")
		}},
		{"point in time excludes later writes", func(t *testing.T) {
			p.sql(t, "UPDATE sample SET value = 'at-target';")
			p.sql(t, "SELECT pg_create_restore_point('proof_target');")
			p.sql(t, "UPDATE sample SET value = 'too-late'; SELECT pg_switch_wal();")
			p.backrest(t, "check")
			p.restore(t, first.Label, "at-target", "--type=name", "--target=proof_target")
		}},
		{"interrupted backup is not a recovery point", func(t *testing.T) {
			// Compressing 128 MiB gives the observer time to interrupt after data copying starts.
			p.sql(t, `CREATE TABLE ballast AS SELECT repeat(md5(g::text), 1024) AS value
FROM generate_series(1, 4096) AS g;
ALTER TABLE ballast ALTER COLUMN value SET STORAGE EXTERNAL;
UPDATE ballast SET value = value || '!';`)
			before := p.backups(t)
			log, err := os.CreateTemp(p.root, "interrupted-*.log")
			require.NoError(t, err)
			t.Cleanup(func() { require.NoError(t, log.Close()) })
			cmd := p.command(t.Context(), "--type=full", "--compress-type=gz", "--compress-level=9", "backup")
			cmd.Stdout, cmd.Stderr = log, log
			require.NoError(t, cmd.Start())
			t.Cleanup(func() { _ = cmd.Process.Kill() })
			require.Eventually(t, func() bool {
				paths, _ := filepath.Glob(filepath.Join(p.repo, "backup/proof/*F/pg_data/base/*/*"))
				for _, path := range paths {
					if !strings.Contains(path, first.Label) {
						return true
					}
				}
				return false
			}, 30*time.Second, time.Millisecond, "backup never started copying data")
			p.backrest(t, "--force", "stop")
			require.Error(t, cmd.Wait())
			p.backrest(t, "start")
			require.Equal(t, before, p.backups(t), "partial backup must not be selectable")
			p.restore(t, first.Label, "original")
			p.sql(t, "DROP TABLE ballast;")
		}},
		{"missing and corrupt required WAL fail closed", func(t *testing.T) {
			paths, err := filepath.Glob(filepath.Join(p.repo, "archive/proof/18-1", first.Archive.Start[:16], first.Archive.Start+"-*"))
			require.NoError(t, err)
			require.Len(t, paths, 1)
			wal := paths[0]
			original, err := os.ReadFile(wal)
			require.NoError(t, err)
			for _, damage := range []string{"missing", "corrupt"} {
				t.Run(damage, func(t *testing.T) {
					t.Cleanup(func() { require.NoError(t, os.WriteFile(wal, original, 0o600)) })
					if damage == "missing" {
						require.NoError(t, os.Remove(wal))
					} else {
						write(t, wal, "not a WAL segment")
					}
					out, err := p.command(t.Context(), "archive-get", first.Archive.Start, filepath.Join(t.TempDir(), "wal")).CombinedOutput()
					require.Error(t, err, string(out))
					data := filepath.Join(t.TempDir(), "restore")
					p.backrest(t, "--set="+first.Label, "--pg1-path="+data, "--type=immediate", "--archive-mode=off", "restore")
					out, err = p.boot(t, data, "pg_ctl", filepath.Dir(data))
					require.Error(t, err, "incomplete recovery must not accept connections: %s", out)
					log, err := os.ReadFile(data + ".log")
					require.NoError(t, err)
					require.Contains(t, string(log), "could not locate required checkpoint record")
				})
			}
		}},
		{"PostgreSQL major mismatch is refused", func(t *testing.T) {
			data := filepath.Join(t.TempDir(), "restore")
			p.backrest(t, "--set="+first.Label, "--pg1-path="+data, "--type=immediate", "--archive-mode=off", "restore")
			out, err := p.boot(t, data, "/usr/lib/postgresql/17/bin/pg_ctl", filepath.Dir(data))
			require.Error(t, err, string(out))
			log, err := os.ReadFile(data + ".log")
			require.NoError(t, err)
			require.Contains(t, string(log), "database files are incompatible with server")
		}},
		{"native expiry preserves a differential chain", func(t *testing.T) {
			p.sql(t, "UPDATE sample SET value = 'second-full';")
			p.backrest(t, "--type=full", "backup")
			p.sql(t, "UPDATE sample SET value = 'differential';")
			p.backrest(t, "--type=diff", "backup")
			all := p.backups(t)
			retained = all[len(all)-1]
			p.sql(t, "UPDATE sample SET value = 'newest';")
			p.backrest(t, "--type=full", "backup")
			p.backrest(t, "expire")
			all = p.backups(t)
			require.Len(t, all, 3, "two full backups and their differential")
			newest = all[2]
			require.NotEqual(t, first.Label, all[0].Label)
			p.restore(t, retained.Label, "differential")
			p.restore(t, newest.Label, "newest")
			out, err := p.command(t.Context(), "--set="+first.Label, "--pg1-path="+filepath.Join(t.TempDir(), "expired"), "restore").CombinedOutput()
			require.Error(t, err, string(out))
			t.Logf("native catalog after expiry: %s", p.backrest(t, "--output=json", "info"))
		}},
		{"native repository verification", func(t *testing.T) {
			p.backrest(t, "verify")
			t.Logf("retained repository bytes including WAL/catalog: %s", strings.TrimSpace(run(t, "du", "-sb", p.repo)))
		}},
	} {
		if !t.Run(tc.name, tc.run) {
			t.Fatal("stopping dependent proof cases after failure")
		}
	}
	for _, metric := range []string{"memory.peak", "cpu.stat"} {
		value, err := os.ReadFile(filepath.Join("/sys/fs/cgroup", metric))
		if err == nil {
			t.Logf("container %s: %s", metric, strings.TrimSpace(string(value)))
		}
	}
}

type proof struct{ root, config, source, repo string }

type backup struct {
	Label   string
	Archive struct{ Start string }
}

func (p proof) command(ctx context.Context, args ...string) *exec.Cmd {
	return exec.CommandContext(ctx, "pgbackrest", append([]string{"--config=" + p.config, "--stanza=proof"}, args...)...)
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
	out, err := p.boot(t, data, "pg_ctl", socket)
	require.NoError(t, err, "%s", out)
}

func (p proof) boot(t *testing.T, data, binary, socket string) ([]byte, error) {
	t.Helper()
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		_ = exec.CommandContext(ctx, "pg_ctl", "-D", data, "-m", "immediate", "stop").Run()
	})
	// Startup logs use a file: pg_ctl must not leave the server holding Go's output pipe.
	return exec.CommandContext(t.Context(), binary, "-D", data, "-l", data+".log", "-o", "-k "+socket, "-t", "15", "-w", "start").CombinedOutput()
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
