package pgbackrest_test

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/a-novel/infra/internal/recovery"
)

func TestOfflineSQL(t *testing.T) {
	if os.Getenv("INFRA_PGBACKREST_PROOF") != "1" {
		t.Skip("run the disposable pgbackrest-proof image")
	}
	query, err := os.ReadFile("/data.sql")
	require.NoError(t, err)
	dataSQL := string(query)
	p := newProof(t, "json-keys")
	p.sql(t, `CREATE ROLE agora_json_keys LOGIN SUPERUSER;
CREATE ROLE agora_json_keys_backup LOGIN;
GRANT pg_read_all_data TO agora_json_keys_backup;`)
	p.sql(t, "CREATE DATABASE agora_json_keys OWNER agora_json_keys;")
	run(t, "psql", "-X", "-h", p.root, "-d", "agora_json_keys", "-v", "ON_ERROR_STOP=1", "-f", "/docker-entrypoint-initdb.d/init.sql")
	sql := func(query string) string {
		return strings.TrimSpace(run(t, "psql", "-XqAt", "-h", p.root, "-d", "agora_json_keys", "-v", "ON_ERROR_STOP=1", "-c", query))
	}
	// Persisted service columns, including nullable public keys and revocation metadata.
	sql(`CREATE TABLE keys (
id uuid PRIMARY KEY, private_key text NOT NULL CHECK (private_key <> ''), public_key text,
usage text NOT NULL, created_at timestamptz(0) NOT NULL, expires_at timestamptz(0) NOT NULL,
deleted_at timestamptz(0), deleted_comment text);
INSERT INTO keys VALUES
('00000000-0000-0000-0000-000000000001', 'full', NULL, 'auth', '2026-09-30Z', '2027-09-30Z', NULL, NULL),
('00000000-0000-0000-0000-000000000002', 'encrypted', 'public', 'test', '2026-09-29Z', '2027-09-29Z', '2026-09-30Z', E'quoted "é"\nline');
CREATE VIEW active_keys AS SELECT * FROM keys WHERE expires_at > CURRENT_TIMESTAMP AND deleted_at IS NULL;`)
	fullHash := sql(dataSQL)
	require.Regexp(t, `^[a-f0-9]{64}$`, fullHash)
	p.backrest(t, "--type=full", "--archive-copy", "backup")
	full := p.backups(t)[0].Label
	sql("UPDATE keys SET private_key='diff';")
	diffHash := sql(dataSQL)
	require.NotEqual(t, fullHash, diffHash)
	p.backrest(t, "--type=diff", "--archive-copy", "backup")
	diff := p.backups(t)[1].Label
	// Source observations precede recovery; no expected value is learned from restored data.
	sql("CREATE TABLE saved_keys AS TABLE keys;")
	for _, tc := range []struct {
		name, change, settings string
		same                   bool
	}{
		{"OrderAndFormatting", "TRUNCATE keys; INSERT INTO keys SELECT * FROM saved_keys ORDER BY id DESC;", "SET timezone='Pacific/Auckland'; SET datestyle='SQL, DMY';", true},
		{"NullPublicKey", "UPDATE keys SET public_key='' WHERE public_key IS NULL;", "", false},
		{"NullComment", "UPDATE keys SET deleted_comment='' WHERE deleted_comment IS NULL;", "", false},
		{"ChangedUsage", "UPDATE keys SET usage='changed';", "", false},
		{"MissingRow", "DELETE FROM keys WHERE public_key IS NULL;", "", false},
		{"Empty", "TRUNCATE keys;", "", false},
	} {
		t.Run("Fingerprint/"+tc.name, func(t *testing.T) {
			sql(tc.change)
			require.Equal(t, tc.same, sql(tc.settings+dataSQL) == diffHash)
			sql("TRUNCATE keys; INSERT INTO keys SELECT * FROM saved_keys;")
		})
	}
	sql("DELETE FROM keys WHERE public_key IS NULL;")
	missingHash := sql(dataSQL)
	sql("TRUNCATE keys;")
	emptyHash := sql(dataSQL)
	sql("INSERT INTO keys SELECT * FROM saved_keys;")
	for _, set := range []string{full, diff} {
		wal := filepath.Join(p.repo, "backup/json-keys", set, "pg_data/pg_wal")
		t.Logf("copied consistency WAL stored (%s): %s", set, strings.TrimSpace(run(t, "du", "-sb", wal)))
	}
	for _, tc := range []struct{ name, set, expected, fault string }{
		{"Full", full, fullHash, ""},
		{"Differential", diff, diffHash, ""},
		{"LegacySchemaOnly", diff, "", ""},
		{"WrongSet", full, diffHash, "data"},
		{"MissingRow", diff, missingHash, "data"},
		{"EmptyExpectation", diff, emptyHash, "data"},
		{"MissingWAL", diff, diffHash, "wal"},
		{"FailedSQL", diff, diffHash, "sql"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			request := recovery.Request{
				Service: "json-keys", SourceProject: "source-project", Project: "a-novel-recovery-proof", ManagementProject: "management-project",
				ManagementNumber: "123456789012", SystemID: strings.TrimSpace(p.sql(t, "SELECT system_identifier FROM pg_control_system();")), Major: 18, Set: tc.set, VerifySQL: true,
				ExpectedDataSHA256: tc.expected,
			}
			parent := t.TempDir()
			execute := func(ctx context.Context, diagnostics io.Writer, binary string, args ...string) ([]byte, error) {
				if binary == "/usr/bin/pgbackrest" {
					local := []string{"--repo1-type=posix", "--repo1-path=" + p.repo}
					for _, arg := range args {
						if !strings.HasPrefix(arg, "--repo1-") {
							local = append(local, arg)
						}
					}
					args = local
				}
				return recovery.Command(ctx, diagnostics, binary, args...)
			}
			require.NoError(t, recovery.Restore(t.Context(), request, parent, execute))
			// Recovered configuration is evidence, not authority to load startup hooks.
			for _, name := range []string{"postgresql.conf", "postgresql.auto.conf"} {
				require.NoError(t, os.WriteFile(filepath.Join(parent, "attempt/data", name), []byte("shared_preload_libraries='unavailable_proof_library'\n"), 0o600))
			}
			wal := filepath.Join(parent, "attempt/data/pg_wal")
			entries, err := os.ReadDir(wal)
			require.NoError(t, err)
			var walBytes int64
			for _, entry := range entries {
				if entry.IsDir() {
					continue
				}
				info, err := entry.Info()
				require.NoError(t, err)
				walBytes += info.Size()
				if tc.fault == "wal" {
					require.NoError(t, os.Remove(filepath.Join(wal, entry.Name())))
				}
			}
			t.Logf("consistency WAL restored: %d bytes", walBytes)
			require.Positive(t, walBytes)
			// Verification cannot invoke pgBackRest; its startup uses only the restored WAL.
			offline := func(ctx context.Context, diagnostics io.Writer, binary string, args ...string) ([]byte, error) {
				require.NotContains(t, binary, "pgbackrest")
				if tc.fault == "sql" && strings.HasSuffix(binary, "/psql") && strings.Contains(args[len(args)-1], "public.keys") {
					return []byte("f\n"), nil
				}
				return recovery.Command(ctx, diagnostics, binary, args...)
			}
			err = recovery.VerifySQL(t.Context(), request, parent, offline)
			if tc.fault == "" {
				require.NoError(t, err)
			} else {
				message := "JSON Keys recovery checks failed"
				switch tc.fault {
				case "wal":
					message = "offline PostgreSQL startup failed"
				case "data":
					message = "recovered application data differs"
				}
				require.ErrorContains(t, err, message)
			}
			_, resultErr := os.Stat(filepath.Join(parent, "attempt/verification/sql-verified.json"))
			require.Equal(t, tc.fault == "", resultErr == nil)
			require.NoFileExists(t, filepath.Join(parent, "attempt/data/postmaster.pid"))
			require.ErrorContains(t, recovery.VerifySQL(t.Context(), request, parent, offline), "already attempted")
		})
	}
}
