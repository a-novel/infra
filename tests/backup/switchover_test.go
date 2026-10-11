package backup_test

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

// TestSwitchover proves the handoff a database rollout relies on. A standby restored from the
// repository streams from the primary, and takes over only after replaying the primary's shutdown
// checkpoint. The promoted host keeps archiving on its own timeline, under the same stanza.
func TestSwitchover(t *testing.T) {
	if os.Getenv("BACKUP_TEST") != "1" {
		t.Skip("run inside builds/backup-test.Dockerfile")
	}
	p := newProof(t, "proof")
	p.backrest(t, "--type=full", "backup")
	full := p.backups(t)[0].Label
	// Each standby gets its own data directory and socket, as a separate host would, and archives
	// from that directory once promoted.
	standby := func(name string, options ...string) string {
		t.Helper()
		data, socket := filepath.Join(p.root, name), t.TempDir()
		p.backrest(t, append([]string{"--pg1-path=" + data, "--type=standby"}, append(options, "restore")...)...)
		file, err := os.OpenFile(filepath.Join(data, "postgresql.conf"), os.O_APPEND|os.O_WRONLY, 0)
		require.NoError(t, err)
		_, err = file.WriteString("archive_command='pgbackrest --config=" + p.config + " --stanza=proof --pg1-path=" + data + " archive-push %p'\n")
		require.NoError(t, err)
		require.NoError(t, file.Close())
		p.start(t, data, socket)
		return socket
	}
	streaming := standby("streaming", "--recovery-option=primary_conninfo=host="+p.root+" user=postgres")
	archived := standby("archived")
	// Polled conditions must not fail the test from testify's goroutine.
	poll := func(socket, sql string) string {
		out, _ := exec.CommandContext(t.Context(), "psql", "-XAt", "-h", socket, "-d", "postgres", "-c", sql).Output()
		return string(out)
	}
	connected := func() bool { return poll(streaming, "SELECT status FROM pg_stat_wal_receiver;") == "streaming\n" }
	// The gate: the standby has replayed the stopped primary's last record, its shutdown checkpoint.
	caughtUp := func(socket, checkpoint string) bool {
		return poll(socket, "SELECT pg_last_wal_replay_lsn() > '"+checkpoint+"';") == "t\n"
	}
	var checkpoint string
	for _, tc := range []struct {
		name string
		run  func(*testing.T)
	}{
		{"Success/Streaming", func(t *testing.T) {
			require.Eventually(t, connected, 20*time.Second, 100*time.Millisecond)
		}},
		{"Success/AbortBeforePromotion", func(t *testing.T) {
			// Restarting a cleanly stopped primary must not conflict with what it already archived.
			p.stop(t, p.source)
			// The proof's cleanup stops this directory; a case's own cleanup would stop it too early.
			run(t, "pg_ctl", "-D", p.source, "-l", p.source+".log", "-o", "-k "+p.root, "-w", "start")
			p.sql(t, "UPDATE sample SET value = 'restarted';")
			p.backrest(t, "check")
		}},
		{"Success/Handoff", func(t *testing.T) {
			// The primary ships its final WAL only to standbys connected while it shuts down.
			require.Eventually(t, connected, 20*time.Second, 100*time.Millisecond)
			p.sql(t, "UPDATE sample SET value = 'streamed';")
			p.stop(t, p.source)
			control := run(t, "pg_controldata", "-D", p.source)
			require.Contains(t, control, "Database cluster state:               shut down\n")
			checkpoint = regexp.MustCompile(`Latest checkpoint location:\s+(\S+)`).FindStringSubmatch(control)[1]
			require.Eventually(t, func() bool { return caughtUp(streaming, checkpoint) }, 20*time.Second, 100*time.Millisecond)
			require.Equal(t, "streamed\n", query(t, streaming, "SELECT value FROM sample;"))
		}},
		{"Error/ArchiveOnlyStandby", func(t *testing.T) {
			// A stopped primary never archives its last, partial segment: replaying the archive
			// alone never reaches the shutdown checkpoint.
			require.Eventually(t, func() bool { return poll(archived, "SELECT value FROM sample;") == "restarted\n" }, 20*time.Second, 100*time.Millisecond)
			require.Never(t, func() bool { return caughtUp(archived, checkpoint) }, 3*time.Second, 100*time.Millisecond)
		}},
		{"Success/Promotion", func(t *testing.T) {
			require.Equal(t, "t\n", query(t, streaming, "SELECT pg_promote();"))
			require.Equal(t, "00000002\n", query(t, streaming, "SELECT left(pg_walfile_name(pg_current_wal_lsn()), 8);"))
			// pg_control keeps the old timeline until a checkpoint, and pgBackRest refuses to back up
			// until they match.
			query(t, streaming, "CHECKPOINT;")
			query(t, streaming, "UPDATE sample SET value = 'promoted';")
			host := []string{"--pg1-path=" + filepath.Join(p.root, "streaming"), "--pg1-socket-path=" + streaming}
			p.backrest(t, append(host, "check")...)
			p.backrest(t, append(host, "--type=diff", "backup")...)
		}},
		{"Success/RestoreAcrossTimelines", func(t *testing.T) {
			// Recovery follows the latest timeline, so a backup from before the switch still
			// restores the promoted host's writes.
			p.restore(t, full, "promoted", "--type=default")
		}},
	} {
		if !t.Run(tc.name, tc.run) {
			t.Fatal("stopping dependent switchover cases after failure")
		}
	}
}
