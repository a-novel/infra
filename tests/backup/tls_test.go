package backup_test

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

// TestRepositoryTLS uses loopback inside the offline container, not cloud or host networking.
// The cases share a server and backup set so a denial always has a positive control.
func TestRepositoryTLS(t *testing.T) {
	if os.Getenv("BACKUP_TEST") != "1" {
		t.Skip("run inside builds/backup-test.Dockerfile")
	}
	p := newProof(t, "proof")
	config, err := os.ReadFile(p.config)
	require.NoError(t, err)
	serverConfig := filepath.Join(p.root, "server.conf")
	run(t, "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "90",
		"-keyout", p.root+"/ca.key", "-out", p.root+"/ca.crt", "-subj", "/CN=proof-ca",
		"-addext", "basicConstraints=critical,CA:TRUE")
	issue := func(t *testing.T, name, days string) {
		t.Helper()
		path := filepath.Join(p.root, name)
		run(t, "openssl", "x509", "-req", "-in", path+".csr", "-out", path+".crt", "-days", days, "-copy_extensions", "copy",
			"-CA", p.root+"/ca.crt", "-CAkey", p.root+"/ca.key", "-CAcreateserial")
		certificate, err := os.ReadFile(path + ".crt")
		require.NoError(t, err)
		key, err := os.ReadFile(path + ".key")
		require.NoError(t, err)
		write(t, path+".pem", string(certificate)+string(key))
	}
	for _, name := range []string{"client", "peer", "localhost"} {
		path := filepath.Join(p.root, name)
		run(t, "openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", path+".key",
			"-out", path+".csr", "-subj", "/CN="+name, "-addext", "subjectAltName=DNS:"+name)
		issue(t, name, "90")
	}
	write(t, serverConfig, strings.Replace(string(config), "[global]", fmt.Sprintf(`[global]
tls-server-address=127.0.0.1
tls-server-auth=client=proof
tls-server-ca-file=%[1]s/ca.crt
tls-server-cert-file=%[1]s/localhost.pem
tls-server-key-file=%[1]s/localhost.pem
`, p.root), 1)+"\n[peer]\n")
	write(t, p.config, strings.Replace(string(config), "[global]", fmt.Sprintf(`[global]
repo1-host=localhost
repo1-host-type=tls
repo1-host-config=%[1]s
repo1-host-ca-file=%[2]s/ca.crt
repo1-host-cert-file=%[2]s/client.pem
repo1-host-key-file=%[2]s/client.pem
`, serverConfig, p.root), 1))
	stop := startRepository(t, serverConfig)
	restart := func() {
		stop()
		stop = startRepository(t, serverConfig)
	}
	check := func(t *testing.T, server string) (string, error) {
		t.Helper()
		out, err := exec.CommandContext(t.Context(), "bash", "/check-backup.sh", server,
			p.root+"/ca.crt", p.root+"/client.pem", "--config="+p.config, "--stanza=proof", "repo-ls").CombinedOutput()
		return string(out), err
	}
	var set string
	for _, tc := range []struct {
		name string
		run  func(*testing.T)
	}{
		{"TLSDeadline", func(t *testing.T) {
			out, err := check(t, "localhost")
			require.NoError(t, err, out)
			require.Contains(t, out, "remain valid for at least 30 days")
			require.True(t, strings.HasSuffix(out, "archive\nbackup\n"), out)
			out, err = check(t, "127.0.0.1")
			require.Error(t, err, out)
			require.Contains(t, out, "hostname mismatch")
			for _, name := range []string{"client", "localhost", "ca"} {
				passed := t.Run(name, func(t *testing.T) {
					path := p.root + "/" + name + ".pem"
					if name == "ca" {
						path = p.root + "/ca.crt"
					}
					original, err := os.ReadFile(path)
					require.NoError(t, err)
					t.Cleanup(func() { require.NoError(t, os.WriteFile(path, original, 0o600)) })
					if name == "ca" {
						run(t, "openssl", "req", "-x509", "-key", p.root+"/ca.key", "-days", "1",
							"-out", path, "-subj", "/CN=proof-ca", "-addext", "basicConstraints=critical,CA:TRUE")
					} else {
						issue(t, name, "1")
					}
					restart()
					p.backrest(t, "repo-ls") // Still valid today: only the advance warning must fail.
					out, err := check(t, "localhost")
					require.Error(t, err, out)
					require.Contains(t, out, "certificate has expired")
				})
				if !passed {
					t.Fatal("stopping after unexpected TLS deadline behavior")
				}
				restart()
				out, err := check(t, "localhost")
				require.NoError(t, err, out)
			}
		}},
		{"Success/BackupAndSQLRecovery", func(t *testing.T) {
			p.backrest(t, "check")
			p.backrest(t, "--type=full", "--repo1-bundle", "backup")
			set = p.backups(t)[0].Label
			p.restore(t, set, "original")
		}},
		{"Error/UnauthorizedClient", func(t *testing.T) {
			out, err := p.command(t.Context(), "--repo1-host-cert-file="+p.root+"/peer.pem", "--repo1-host-key-file="+p.root+"/peer.pem", "repo-ls").CombinedOutput()
			require.Error(t, err, string(out))
			require.Contains(t, string(out), "access denied")
			p.backrest(t, "repo-ls")
		}},
		{"Error/UnauthorizedStanza", func(t *testing.T) {
			out, err := exec.CommandContext(t.Context(), "pgbackrest", "--config="+p.config, "--stanza=peer", "repo-ls").CombinedOutput()
			require.Error(t, err, string(out))
			require.Contains(t, string(out), "access denied")
			p.backrest(t, "repo-ls")
		}},
	} {
		if !t.Run(tc.name, tc.run) {
			t.Fatal("stopping dependent transport cases after failure")
		}
	}
}

// startRepository keeps native server output out of the client's pipes and reaps the process.
func startRepository(t *testing.T, config string) func() {
	t.Helper()
	// Cleanup owns termination: t.Context is canceled before cleanup callbacks run.
	cmd := exec.Command("pgbackrest", "--config="+config, "server")
	cmd.Stdout, cmd.Stderr = os.Stderr, os.Stderr
	require.NoError(t, cmd.Start())
	stop := func() {
		if cmd.ProcessState == nil {
			// This fixture exercises an outage; SIGTERM can leave the idle accept loop waiting.
			require.NoError(t, cmd.Process.Kill())
			var exit *exec.ExitError
			require.ErrorAs(t, cmd.Wait(), &exit)
			require.Equal(t, syscall.SIGKILL, exit.Sys().(syscall.WaitStatus).Signal())
		}
	}
	t.Cleanup(stop)
	require.Eventually(t, func() bool {
		return exec.CommandContext(t.Context(), "pgbackrest", "--config="+config, "--io-timeout=1", "server-ping").Run() == nil
	}, 10*time.Second, 100*time.Millisecond, "repository server did not start")
	return stop
}
