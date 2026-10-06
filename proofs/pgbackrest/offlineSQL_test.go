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
	// Each case owns a synthetic cluster; child cases evolve its full/differential chain.
	for _, service := range []string{"json-keys", "authentication"} {
		t.Run(service, func(t *testing.T) { testOfflineSQL(t, service) })
	}
}

func testOfflineSQL(t *testing.T, service string) {
	t.Helper()
	queryFile := "/data.sql"
	if service == "authentication" {
		queryFile = "/authenticationData.sql"
	}
	query, err := os.ReadFile(queryFile)
	require.NoError(t, err)
	dataSQL := string(query)
	p := newProof(t, service)
	role := "agora_" + strings.ReplaceAll(service, "-", "_")
	p.sql(t, "CREATE ROLE "+role+" LOGIN SUPERUSER; CREATE ROLE "+role+"_backup LOGIN; GRANT pg_read_all_data TO "+role+"_backup;")
	p.sql(t, "CREATE DATABASE "+role+" OWNER "+role+";")
	run(t, "psql", "-X", "-h", p.root, "-d", role, "-v", "ON_ERROR_STOP=1", "-f", "/docker-entrypoint-initdb.d/init.sql")
	sql := func(query string) string {
		return strings.TrimSpace(run(t, "psql", "-XqAt", "-h", p.root, "-d", role, "-v", "ON_ERROR_STOP=1", "-c", query))
	}
	table, update, missing := "keys", "UPDATE keys SET private_key='diff';", "DELETE FROM keys WHERE public_key IS NULL;"
	// Persisted service columns, including nullable public keys and revocation metadata.
	if service == "json-keys" {
		sql(`CREATE TABLE keys (
id uuid PRIMARY KEY, private_key text NOT NULL CHECK (private_key <> ''), public_key text,
usage text NOT NULL, created_at timestamptz(0) NOT NULL, expires_at timestamptz(0) NOT NULL,
deleted_at timestamptz(0), deleted_comment text);
INSERT INTO keys VALUES
('00000000-0000-0000-0000-000000000001', 'full', NULL, 'auth', '2026-09-30Z', '2027-09-30Z', NULL, NULL),
('00000000-0000-0000-0000-000000000002', 'encrypted', 'public', 'test', '2026-09-29Z', '2027-09-29Z', '2026-09-30Z', E'quoted "é"\nline');
CREATE VIEW active_keys AS SELECT * FROM keys WHERE expires_at > CURRENT_TIMESTAMP AND deleted_at IS NULL;`)
	} else {
		table, update, missing = "credentials", "UPDATE credentials SET password='diff';", "DELETE FROM credentials WHERE email='two@example.test';"
		sql(`CREATE TABLE credentials (
id uuid PRIMARY KEY, email text NOT NULL UNIQUE CHECK (email <> ''), password text,
created_at timestamptz(0) NOT NULL, updated_at timestamptz(0) NOT NULL, role text NOT NULL);
CREATE TABLE short_codes (
id uuid PRIMARY KEY, code text NOT NULL, usage text NOT NULL, target text NOT NULL, data bytea,
created_at timestamptz(0) NOT NULL, expires_at timestamptz(0) NOT NULL, deleted_at timestamptz(0), deleted_comment text);
INSERT INTO credentials VALUES
('00000000-0000-0000-0000-000000000001', 'one@example.test', 'hash', '2026-09-30Z', '2026-09-30Z', 'auth:user'),
('00000000-0000-0000-0000-000000000002', 'two@example.test', NULL, '2026-09-30Z', '2026-09-30Z', 'auth:admin');
INSERT INTO short_codes VALUES
('00000000-0000-0000-0000-000000000001', 'encrypted', 'test', 'one@example.test', decode('00ff', 'hex'), '2026-09-30Z', '2027-09-30Z', NULL, NULL);
CREATE TABLE saved_short_codes AS TABLE short_codes;`)
	}
	fullHash := sql(dataSQL)
	require.Regexp(t, `^[a-f0-9]{64}$`, fullHash)
	p.backrest(t, "--type=full", "--archive-copy", "backup")
	full := p.backups(t)[0].Label
	sql(update)
	diffHash := sql(dataSQL)
	require.NotEqual(t, fullHash, diffHash)
	p.backrest(t, "--type=diff", "--archive-copy", "backup")
	diff := p.backups(t)[1].Label
	// Source observations precede recovery; no expected value is learned from restored data.
	sql("CREATE TABLE saved_rows AS TABLE " + table + ";")
	cases := []struct {
		name, change, settings string
		same                   bool
	}{
		{"OrderAndFormatting", "TRUNCATE keys; INSERT INTO keys SELECT * FROM saved_rows ORDER BY id DESC;", "SET timezone='Pacific/Auckland'; SET datestyle='SQL, DMY';", true},
		{"NullPublicKey", "UPDATE keys SET public_key='' WHERE public_key IS NULL;", "", false},
		{"NullComment", "UPDATE keys SET deleted_comment='' WHERE deleted_comment IS NULL;", "", false},
		{"ChangedUsage", "UPDATE keys SET usage='changed';", "", false},
		{"MissingRow", "DELETE FROM keys WHERE public_key IS NULL;", "", false},
		{"Empty", "TRUNCATE keys;", "", false},
	}
	if service == "authentication" {
		cases[0].change = "TRUNCATE credentials; INSERT INTO credentials SELECT * FROM saved_rows ORDER BY id DESC;"
		cases[1].name, cases[1].change = "NullPassword", "UPDATE credentials SET password=NULL;"
		cases[2].name, cases[2].change = "EncryptedCode", "UPDATE short_codes SET code='changed';"
		cases[3].name, cases[3].change = "BinaryPayload", "UPDATE short_codes SET data=decode('ff00', 'hex');"
		cases[4].change = "DELETE FROM credentials WHERE email='two@example.test';"
		cases[5].change = "TRUNCATE credentials;"
	}
	for _, tc := range cases {
		t.Run("Fingerprint/"+tc.name, func(t *testing.T) {
			sql(tc.change)
			require.Equal(t, tc.same, sql(tc.settings+dataSQL) == diffHash)
			sql("TRUNCATE " + table + "; INSERT INTO " + table + " SELECT * FROM saved_rows;")
			if service == "authentication" {
				sql("TRUNCATE short_codes; INSERT INTO short_codes SELECT * FROM saved_short_codes;")
			}
		})
	}
	sql(missing)
	missingHash := sql(dataSQL)
	sql("TRUNCATE " + table + ";")
	emptyHash := sql(dataSQL)
	sql("INSERT INTO " + table + " SELECT * FROM saved_rows;")
	for _, set := range []string{full, diff} {
		wal := filepath.Join(p.repo, "backup", service, set, "pg_data/pg_wal")
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
				Service: service, SourceProject: "source-project", Project: "a-novel-recovery-proof", ManagementProject: "management-project",
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
				if tc.fault == "sql" && strings.HasSuffix(binary, "/psql") && strings.Contains(args[len(args)-1], "public."+table) {
					return []byte("f\n"), nil
				}
				return recovery.Command(ctx, diagnostics, binary, args...)
			}
			err = recovery.VerifySQL(t.Context(), request, parent, offline)
			if tc.fault == "" {
				require.NoError(t, err)
			} else {
				message := "service recovery checks failed"
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
