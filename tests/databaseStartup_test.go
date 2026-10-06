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
	for _, service := range []string{"json-keys", "authentication"} {
		for _, tc := range []struct {
			name, supervised, wal, health, passwordStatus, exitStatus string
			code                                                      int
		}{
			{"Success/Legacy", "false", "true", "healthy", "0", "0", 0},
			{"Success/Supervised", "true", "", "healthy", "0", "0", 0},
			{"Success/Archiving", "true", "true", "healthy", "0", "0", 0},
			{"Error/ArchivingValue", "true", "invalid", "healthy", "0", "0", 1},
			{"Error/Health", "true", "false", "unhealthy", "0", "0", 1},
			{"Error/Password", "true", "false", "healthy", "1", "0", 1},
			{"Error/ContainerExit", "true", "false", "healthy", "0", "137", 137},
			{"Error/Collation", "true", "false", "healthy", "0", "0", 1},
		} {
			t.Run(service+"/"+tc.name, func(t *testing.T) {
				t.Parallel()
				f := setup(t)
				f.env["HEALTH"], f.env["PASSWORD_STATUS"], f.env["EXIT_STATUS"] = tc.health, tc.passwordStatus, tc.exitStatus
				f.env["PGBACKREST_WAL_ARCHIVING"] = tc.wal
				f.env["COLLATION_STATUS"] = "0"
				if tc.name == "Error/Collation" {
					f.env["COLLATION_STATUS"] = "1"
				}
				code, out := f.run(t, "bash", "-c", `
. assets/database-host/startup.sh
DATABASE_SUPERVISED="$1"
DATABASE_COMPONENT="$2"
SECRETS_DIR="$TMPDIR"
DATABASE_IP=10.90.0.2
CONTAINER_CPU=0.75
CONTAINER_MEMORY_MB=1536
MAX_CONNECTIONS=50
PGBACKREST_REPOSITORY_NAME=repository.test
PGBACKREST_REPOSITORY_IP=10.90.0.3
prepare_database_directory() { :; }
prepare_database_collations() { printf 'collations\n'; return "$COLLATION_STATUS"; }
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
        "wait agora-postgres-$DATABASE_COMPONENT") printf '%s' "$EXIT_STATUS" ;;
        *) printf 'unexpected Docker call\n' >&2; return 90 ;;
    esac
}
start_database "$DATABASE_COMPONENT" image 5432 user database /password /backup-password
if [ "$DATABASE_SUPERVISED" = true ]; then supervise_database; fi
`, "startup-test", tc.supervised, service)
				expectCode(t, tc.code, code, out)
				if tc.wal == "invalid" || tc.name == "Error/Collation" {
					require.NoFileExists(t, filepath.Join(f.dir, "arguments"))
					return
				}
				args := strings.ReplaceAll(read(t, filepath.Join(f.dir, "arguments")), "\n", " ")
				require.Contains(t, out, "collations\n")
				native := tc.supervised == "true"
				restart := "on-failure:5"
				if native {
					restart = "no"
				}
				require.Contains(t, args, "--restart "+restart)
				archiving := native && tc.wal == "true"
				for option, want := range map[string]bool{
					"unix_socket_directories=/var/run/postgresql,/tmp": native,
					"archive_mode=off": native && !archiving,
					"archive_mode=on":  archiving,
					"archive_command=pgbackrest --stanza=" + service + " archive-push %p": archiving,
					"source=/run/agora/postgresql,target=/var/run/postgresql":             native,
					"source=/run/agora/pgbackrest-lock,target=/run/pgbackrest-lock":       native,
					"repository.test:10.90.0.3":                                           native,
				} {
					require.Equal(t, want, strings.Contains(args, option), option)
				}
				require.Equal(t, native && tc.health == "healthy" && tc.passwordStatus == "0", strings.Contains(out, "credentials\nready\n"))
			})
		}
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
