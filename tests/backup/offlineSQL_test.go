package backup_test

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

// offlineSQLFixture holds one service's synthetic data and the changes its data digest must detect.
type offlineSQLFixture struct {
	service string
	// queryFile is the service's data digest query inside the test image.
	queryFile string
	// schema creates the service's persisted columns, including nullable and binary ones, and fills them.
	schema string
	// table is the main table, saved as saved_rows and refilled from it after each change.
	table string
	// reset refills the service's other tables from their saved copies.
	reset string
	// update changes every row between the full and the differential backup.
	update string
	// missing deletes one row.
	missing string
	// fingerprints are changes made after the differential backup.
	fingerprints []fingerprintCase
}

// fingerprintCase is a change to the data, and whether the digest, read with settings, stays the same.
type fingerprintCase struct {
	name, change, settings string
	same                   bool
}

// formatting changes how the session prints dates and times, which the digest must ignore.
const formatting = "SET timezone='Pacific/Auckland'; SET datestyle='SQL, DMY';"

var offlineSQLFixtures = []offlineSQLFixture{
	{
		service:   "json-keys",
		queryFile: "/jsonKeysData.sql",
		schema: `CREATE TABLE keys (
id uuid PRIMARY KEY, private_key text NOT NULL CHECK (private_key <> ''), public_key text,
usage text NOT NULL, created_at timestamptz(0) NOT NULL, expires_at timestamptz(0) NOT NULL,
deleted_at timestamptz(0), deleted_comment text);
INSERT INTO keys VALUES
('00000000-0000-0000-0000-000000000001', 'full', NULL, 'auth', '2026-09-30Z', '2027-09-30Z', NULL, NULL),
('00000000-0000-0000-0000-000000000002', 'encrypted', 'public', 'test', '2026-09-29Z', '2027-09-29Z', '2026-09-30Z', E'quoted "é"\nline');
CREATE VIEW active_keys AS SELECT * FROM keys WHERE expires_at > CURRENT_TIMESTAMP AND deleted_at IS NULL;`,
		table:   "keys",
		update:  "UPDATE keys SET private_key='diff';",
		missing: "DELETE FROM keys WHERE public_key IS NULL;",
		fingerprints: []fingerprintCase{
			{"OrderAndFormatting", "TRUNCATE keys; INSERT INTO keys SELECT * FROM saved_rows ORDER BY id DESC;", formatting, true},
			{"NullPublicKey", "UPDATE keys SET public_key='' WHERE public_key IS NULL;", "", false},
			{"NullComment", "UPDATE keys SET deleted_comment='' WHERE deleted_comment IS NULL;", "", false},
			{"ChangedUsage", "UPDATE keys SET usage='changed';", "", false},
			{"MissingRow", "DELETE FROM keys WHERE public_key IS NULL;", "", false},
			{"Empty", "TRUNCATE keys;", "", false},
		},
	},
	{
		service:   "authentication",
		queryFile: "/authenticationData.sql",
		schema: `CREATE TABLE credentials (
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
CREATE TABLE saved_short_codes AS TABLE short_codes;`,
		table:   "credentials",
		reset:   "TRUNCATE short_codes; INSERT INTO short_codes SELECT * FROM saved_short_codes;",
		update:  "UPDATE credentials SET password='diff';",
		missing: "DELETE FROM credentials WHERE email='two@example.test';",
		fingerprints: []fingerprintCase{
			{"OrderAndFormatting", "TRUNCATE credentials; INSERT INTO credentials SELECT * FROM saved_rows ORDER BY id DESC;", formatting, true},
			{"NullPassword", "UPDATE credentials SET password=NULL;", "", false},
			{"EncryptedCode", "UPDATE short_codes SET code='changed';", "", false},
			{"BinaryPayload", "UPDATE short_codes SET data=decode('ff00', 'hex');", "", false},
			{"MissingRow", "DELETE FROM credentials WHERE email='two@example.test';", "", false},
			{"Empty", "TRUNCATE credentials;", "", false},
		},
	},
}

func TestOfflineSQL(t *testing.T) {
	if os.Getenv("BACKUP_TEST") != "1" {
		t.Skip("run inside builds/backup-test.Dockerfile")
	}
	// Each case owns a synthetic cluster; child cases evolve its full/differential chain.
	for _, fixture := range offlineSQLFixtures {
		t.Run(fixture.service, func(t *testing.T) { testOfflineSQL(t, fixture) })
	}
}

func testOfflineSQL(t *testing.T, fixture offlineSQLFixture) {
	t.Helper()
	query, err := os.ReadFile(fixture.queryFile)
	require.NoError(t, err)
	dataSQL := string(query)
	p := newProof(t, fixture.service)
	role := "agora_" + strings.ReplaceAll(fixture.service, "-", "_")
	p.query(t, "postgres", "CREATE ROLE "+role+" LOGIN SUPERUSER; CREATE ROLE "+role+"_app LOGIN; CREATE ROLE "+role+"_backup LOGIN; GRANT pg_read_all_data TO "+role+"_backup;")
	p.query(t, "postgres", "CREATE DATABASE "+role+" OWNER "+role+";")
	run(t, "psql", "-X", "-h", p.root, "-d", role, "-v", "ON_ERROR_STOP=1", "-f", "/docker-entrypoint-initdb.d/init.sql")
	table := fixture.table
	p.query(t, role, fixture.schema)

	fullHash := p.query(t, role, dataSQL)
	require.Regexp(t, `^[a-f0-9]{64}$`, fullHash)
	p.backrest(t, "--type=full", "--archive-copy", "backup")
	full := p.backups(t)[0].Label

	p.query(t, role, fixture.update)
	diffHash := p.query(t, role, dataSQL)
	require.NotEqual(t, fullHash, diffHash)
	p.backrest(t, "--type=diff", "--archive-copy", "backup")
	diff := p.backups(t)[1].Label

	// Source observations precede recovery; no expected value is learned from restored data.
	p.query(t, role, "CREATE TABLE saved_rows AS TABLE "+table+";")
	for _, tc := range fixture.fingerprints {
		t.Run("Fingerprint/"+tc.name, func(t *testing.T) {
			p.query(t, role, tc.change)
			require.Equal(t, tc.same, p.query(t, role, tc.settings+dataSQL) == diffHash)
			p.query(t, role, "TRUNCATE "+table+"; INSERT INTO "+table+" SELECT * FROM saved_rows;")
			if fixture.reset != "" {
				p.query(t, role, fixture.reset)
			}
		})
	}

	p.query(t, role, fixture.missing)
	missingHash := p.query(t, role, dataSQL)
	p.query(t, role, "TRUNCATE "+table+";")
	emptyHash := p.query(t, role, dataSQL)
	p.query(t, role, "INSERT INTO "+table+" SELECT * FROM saved_rows;")
	systemID := p.query(t, "postgres", "SELECT system_identifier FROM pg_control_system();")

	sets := []string{full, diff}
	for _, set := range sets {
		wal := filepath.Join(p.repo, "backup", fixture.service, set, "pg_data/pg_wal")
		t.Logf("copied consistency WAL stored (%s): %s", set, strings.TrimSpace(run(t, "du", "-sb", wal)))
	}

	faultErrors := map[string]string{
		"wal":  "offline PostgreSQL startup failed",
		"data": "recovered application data differs",
		"sql":  "service recovery checks failed",
	}
	restoreCases := []struct{ name, set, expected, fault string }{
		{"Full", full, fullHash, ""},
		{"Differential", diff, diffHash, ""},
		{"LegacySchemaOnly", diff, "", ""},
		{"WrongSet", full, diffHash, "data"},
		{"MissingRow", diff, missingHash, "data"},
		{"EmptyExpectation", diff, emptyHash, "data"},
		{"MissingWAL", diff, diffHash, "wal"},
		{"FailedSQL", diff, diffHash, "sql"},
	}
	for _, tc := range restoreCases {
		t.Run(tc.name, func(t *testing.T) {
			request := recovery.Request{
				Service:            fixture.service,
				SourceProject:      "source-project",
				Project:            "a-novel-recovery-proof",
				ManagementProject:  "management-project",
				ManagementNumber:   "123456789012",
				SystemID:           systemID,
				Major:              18,
				Set:                tc.set,
				VerifySQL:          true,
				ExpectedDataSHA256: tc.expected,
			}
			parent := t.TempDir()
			require.NoError(t, recovery.Restore(t.Context(), request, parent, p.localCommand(t)))

			// Recovered configuration is evidence, not authority to load startup hooks.
			configs := []string{"postgresql.conf", "postgresql.auto.conf"}
			for _, name := range configs {
				require.NoError(t, os.WriteFile(filepath.Join(parent, "attempt/data", name), []byte("shared_preload_libraries='unavailable_proof_library'\n"), 0o600))
			}
			walBytes := restoredWAL(t, filepath.Join(parent, "attempt/data/pg_wal"), tc.fault == "wal")
			t.Logf("consistency WAL restored: %d bytes", walBytes)
			require.Positive(t, walBytes)

			// Verification cannot invoke pgBackRest; its startup uses only the restored WAL.
			offline := offlineCommand(t, tc.fault == "sql", table)
			err := recovery.VerifySQL(t.Context(), request, parent, offline)
			if tc.fault == "" {
				require.NoError(t, err)
			} else {
				require.ErrorContains(t, err, faultErrors[tc.fault])
			}

			_, resultErr := os.Stat(filepath.Join(parent, "attempt/verification/sql-verified.json"))
			require.Equal(t, tc.fault == "", resultErr == nil)
			require.NoFileExists(t, filepath.Join(parent, "attempt/data/postmaster.pid"))
			require.ErrorContains(t, recovery.VerifySQL(t.Context(), request, parent, offline), "already attempted")
		})
	}
}

// restoredWAL sums the size of the WAL files in dir, deleting each one when remove is set.
func restoredWAL(t *testing.T, dir string, remove bool) int64 {
	t.Helper()
	entries, err := os.ReadDir(dir)
	require.NoError(t, err)
	var size int64
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		info, err := entry.Info()
		require.NoError(t, err)
		size += info.Size()
		if remove {
			require.NoError(t, os.Remove(filepath.Join(dir, entry.Name())))
		}
	}
	return size
}

// offlineCommand runs native tools as VerifySQL does and fails any pgBackRest call. With failSchema
// set, the schema check of the service whose main table is table answers false.
func offlineCommand(t *testing.T, failSchema bool, table string) recovery.Executor {
	return func(ctx context.Context, diagnostics io.Writer, binary string, args ...string) ([]byte, error) {
		require.NotContains(t, binary, "pgbackrest")
		if failSchema && strings.HasSuffix(binary, "/psql") && strings.Contains(args[len(args)-1], "public."+table) {
			return []byte("f\n"), nil
		}
		return recovery.Command(ctx, diagnostics, binary, args...)
	}
}
