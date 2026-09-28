package tests_test

import (
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

// TestDatabaseStartup exercises the shared adapter without disks, Docker or cloud credentials.
func TestDatabaseStartup(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name, supervised, health, passwordStatus, exitStatus string
		code                                                 int
	}{
		{"Success/Legacy", "false", "healthy", "0", "0", 0},
		{"Success/Supervised", "true", "healthy", "0", "0", 0},
		{"Error/Health", "true", "unhealthy", "0", "0", 1},
		{"Error/Password", "true", "healthy", "1", "0", 1},
		{"Error/ContainerExit", "true", "healthy", "0", "137", 137},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			f := setup(t)
			f.env["HEALTH"], f.env["PASSWORD_STATUS"], f.env["EXIT_STATUS"] = tc.health, tc.passwordStatus, tc.exitStatus
			code, out := f.run(t, "bash", "-c", `
. assets/database-host/startup.sh
DATABASE_SUPERVISED="$1"
DATABASE_COMPONENT=json-keys
SECRETS_DIR="$TMPDIR"
DATABASE_IP=10.90.0.2
CONTAINER_CPU=0.75
CONTAINER_MEMORY_MB=1536
MAX_CONNECTIONS=50
PGBACKREST_REPOSITORY_NAME=repository.test
PGBACKREST_REPOSITORY_IP=10.90.0.3
prepare_database_directory() { :; }
activate_database_credentials() { printf 'credentials\n'; return "$PASSWORD_STATUS"; }
systemd-notify() { printf 'ready\n'; }
publish_database_status() { printf '%s\n' "$1"; }
sleep() { :; }
docker() {
    case "$1 $2" in
        'container inspect') return 1 ;;
        'run --detach') printf '%s\n' "$@" > "$TMPDIR/arguments" ;;
        'inspect --format')
            case "$3" in *Running*) printf true;; *) printf '%s' "$HEALTH";; esac ;;
        'wait agora-postgres-json-keys') printf '%s' "$EXIT_STATUS" ;;
        *) printf 'unexpected Docker call\n' >&2; return 90 ;;
    esac
}
start_database json-keys image 5432 user database /password /backup-password
if [ "$DATABASE_SUPERVISED" = true ]; then supervise_database; fi
`, "startup-test", tc.supervised)
			expectCode(t, tc.code, code, out)
			args := strings.Split(strings.TrimSpace(read(t, filepath.Join(f.dir, "arguments"))), "\n")
			native := tc.supervised == "true"
			restart := "on-failure:5"
			if native {
				restart = "no"
			}
			require.Contains(t, strings.Join(args, " "), "--restart "+restart)
			require.Equal(t, native, strings.Contains(strings.Join(args, " "), "archive_mode=off"))
			require.Equal(t, native, strings.Contains(strings.Join(args, " "), "repository.test:10.90.0.3"))
			require.Equal(t, native && tc.health == "healthy" && tc.passwordStatus == "0", strings.Contains(out, "credentials\nready\n"))
		})
	}
}

func TestDatabaseFirewall(t *testing.T) {
	t.Parallel()
	for _, supervised := range []string{"false", "true"} {
		t.Run(supervised, func(t *testing.T) {
			t.Parallel()
			f := setup(t)
			code, out := f.run(t, "bash", "-c", `
. assets/database-host/startup.sh
DATABASE_SUPERVISED="$1"
PGBACKREST_REPOSITORY_IP=10.90.0.3
iptables() {
    if [[ "$*" == *' -D '* ]]; then return 1; fi
    printf '%s\n' "$*"
}
configure_database_firewall
`, "firewall-test", supervised)
			expectCode(t, 0, code, out)
			expected := []string{
				"-w -N AGORA-DATABASE-EGRESS", "-w -F AGORA-DATABASE-EGRESS",
				"-w -A AGORA-DATABASE-EGRESS -s 172.31.254.0/30 -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN",
			}
			if supervised == "true" {
				expected = append(expected, "-w -A AGORA-DATABASE-EGRESS -s 172.31.254.0/30 -d 10.90.0.3 -p tcp --dport 8432 -j RETURN")
			}
			expected = append(expected,
				"-w -A AGORA-DATABASE-EGRESS -s 172.31.254.0/30 -j REJECT",
				"-w -I DOCKER-USER 1 -j AGORA-DATABASE-EGRESS",
				"-w -N AGORA-DATABASE-HOST", "-w -F AGORA-DATABASE-HOST",
				"-w -A AGORA-DATABASE-HOST -s 172.31.254.0/30 -j REJECT",
				"-w -I INPUT 1 -j AGORA-DATABASE-HOST")
			require.Equal(t, strings.Join(expected, "\n")+"\n", out)
		})
	}
}
