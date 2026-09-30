package pgbackrest_test

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
	if os.Getenv("INFRA_PGBACKREST_PROOF") != "1" {
		t.Skip("run the disposable pgbackrest-proof image; see README.md")
	}
	p := newProof(t, "proof")
	config, err := os.ReadFile(p.config)
	require.NoError(t, err)
	serverConfig := filepath.Join(p.root, "server.conf")
	run(t, "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
		"-keyout", p.root+"/ca.key", "-out", p.root+"/ca.crt", "-subj", "/CN=proof-ca",
		"-addext", "basicConstraints=critical,CA:TRUE")
	for _, name := range []string{"client", "peer", "localhost"} {
		path := filepath.Join(p.root, name)
		run(t, "openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", path+".key",
			"-out", path+".csr", "-subj", "/CN="+name, "-addext", "subjectAltName=DNS:"+name)
		run(t, "openssl", "x509", "-req", "-in", path+".csr", "-out", path+".crt", "-days", "1", "-copy_extensions", "copy",
			"-CA", p.root+"/ca.crt", "-CAkey", p.root+"/ca.key", "-CAcreateserial")
		certificate, err := os.ReadFile(path + ".crt")
		require.NoError(t, err)
		key, err := os.ReadFile(path + ".key")
		require.NoError(t, err)
		write(t, path+".pem", string(certificate)+string(key))
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
	var set string
	for _, tc := range []struct {
		name string
		run  func(*testing.T)
	}{
		{"Limit/EmptyRepository", func(t *testing.T) {
			report := p.backrest(t, "--output=text", "--verbose", "--log-level-console=error", "verify")
			require.Contains(t, report, "no archives or backups exist in the repo")
		}},
		{"Success/BackupAndSQLRecovery", func(t *testing.T) {
			p.backrest(t, "check")
			p.backrest(t, "--type=full", "--repo1-bundle", "backup")
			set = p.backups(t)[0].Label
			p.restore(t, set, "original")
		}},
		{"RepositoryIntegrity", func(t *testing.T) {
			bundle := filepath.Join(p.repo, "backup", p.stanza, set, "bundle", "1")
			original, err := os.ReadFile(bundle)
			require.NoError(t, err)
			for _, tc := range []struct {
				name   string
				status string
			}{
				{"Healthy", "ok"},
				{"Missing", "error"},
				{"Corrupt", "error"},
			} {
				passed := t.Run(tc.name, func(t *testing.T) {
					t.Cleanup(func() {
						require.NoError(t, os.WriteFile(bundle, original, 0o600))
					})
					switch tc.name {
					case "Missing":
						require.NoError(t, os.Remove(bundle))
					case "Corrupt":
						write(t, bundle, "corrupt synthetic backup bundle")
					}
					// backrest requires exit zero; only the native report distinguishes damaged files.
					report := p.backrest(t, "--output=text", "--verbose", "--log-level-console=error", "verify")
					require.Contains(t, report, "\nstatus: "+tc.status+"\n")
				})
				if !passed {
					t.Fatal("integrity scenario failed; do not continue with repository mutations")
				}
				require.Contains(t, p.backrest(t, "--output=text", "--verbose", "--log-level-console=error", "verify"), "\nstatus: ok\n")
			}
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
		{"Error/UntrustedServer", func(t *testing.T) {
			out, err := p.command(t.Context(), "--repo1-host-ca-file="+p.root+"/peer.crt", "repo-ls").CombinedOutput()
			require.Error(t, err, string(out))
			require.Contains(t, string(out), "unable to verify certificate")
			p.backrest(t, "repo-ls")
		}},
		{"Limit/ClientOverridesRepository", func(t *testing.T) {
			outside := t.TempDir()
			path := filepath.Join(outside, "outside-repository")
			write(t, path, "synthetic path-override probe")
			require.NoError(t, os.Chmod(path, 0o400))
			out := p.backrest(t, "--repo1-path="+outside, "repo-ls")
			require.Equal(t, "outside-repository\n", out)
			require.Equal(t, "synthetic path-override probe", p.backrest(t, "--repo1-path="+outside, "repo-get", "outside-repository"))
			require.NoError(t, os.Chmod(path, 0o000))
			denied, err := p.command(t.Context(), "--repo1-path="+outside, "repo-get", "outside-repository").CombinedOutput()
			require.Error(t, err, string(denied))
			require.Contains(t, string(denied), "Permission denied")
			p.backrest(t, "repo-ls")
		}},
		{"Error/StoppedRepositoryThenExplicitRetry", func(t *testing.T) {
			stop()
			data := filepath.Join(t.TempDir(), "unavailable")
			out, err := p.command(t.Context(), "--set="+set, "--pg1-path="+data, "--io-timeout=1", "restore").CombinedOutput()
			require.Error(t, err, string(out))
			require.Contains(t, string(out), "unable to connect")
			require.NoFileExists(t, filepath.Join(data, "global", "pg_control"))
			startRepository(t, serverConfig)
			p.restore(t, set, "original")
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
			require.NoError(t, cmd.Process.Signal(syscall.SIGTERM))
			require.NoError(t, cmd.Wait())
		}
	}
	t.Cleanup(stop)
	require.Eventually(t, func() bool {
		return exec.CommandContext(t.Context(), "pgbackrest", "--config="+config, "--io-timeout=1", "server-ping").Run() == nil
	}, 10*time.Second, 100*time.Millisecond, "repository server did not start")
	return stop
}
