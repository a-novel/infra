package pgbackrest_test

import (
	"os"
	"os/exec"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

// TestCollationPreparation executes the shipped SQL against disposable databases.
// Synthetic version markers exercise mismatches without depending on an OS upgrade.
func TestCollationPreparation(t *testing.T) {
	if os.Getenv("INFRA_PGBACKREST_PROOF") != "1" {
		t.Skip("run the disposable pgbackrest-proof image")
	}
	asset, err := os.ReadFile("/database-startup.sh")
	require.NoError(t, err)
	_, sql, found := strings.Cut(string(asset), "SET LOCAL lock_timeout = ")
	require.True(t, found)
	sql, _, found = strings.Cut(sql, "\nSQL\n")
	require.True(t, found)
	sql = "SET LOCAL lock_timeout = " + sql
	p := newProof(t, "collation")
	p.sql(t, "CREATE DATABASE collation_proof LOCALE 'en_US.utf8' TEMPLATE template0;")
	query := func(statement string) string {
		t.Helper()
		out, err := exec.CommandContext(t.Context(), "psql", "-XqAt", "-h", p.root, "-d", "collation_proof", "-v", "ON_ERROR_STOP=1", "-c", statement).Output()
		require.NoError(t, err)
		return strings.TrimSpace(string(out))
	}
	prepare := func() (string, error) {
		cmd := exec.CommandContext(t.Context(), "psql", "-X", "-h", p.root, "-d", "collation_proof", "-v", "ON_ERROR_STOP=1", "--single-transaction")
		cmd.Stdin = strings.NewReader(sql)
		out, err := cmd.CombinedOutput()
		return string(out), err
	}
	query("CREATE TABLE sample (value text PRIMARY KEY); INSERT INTO sample VALUES ('plain'), ('été'), ('Zebra');")
	index := func() string { return query("SELECT relfilenode FROM pg_class WHERE relname='sample_pkey';") }
	before := index()
	markChanged := func() { p.sql(t, "UPDATE pg_database SET datcollversion='proof-old' WHERE datname='collation_proof';") }
	markChanged()
	out, err := prepare()
	require.NoError(t, err, out)
	require.NotEqual(t, before, index())
	require.Equal(t, "t", query("SELECT datcollversion=pg_database_collation_actual_version(oid) FROM pg_database WHERE datname=current_database();"))
	require.Equal(t, "3", query("SELECT count(*) FROM sample;"))
	before = index()
	out, err = prepare()
	require.NoError(t, err, out)
	require.Equal(t, before, index(), "unchanged libraries must not rebuild indexes")

	query("CREATE FUNCTION index_value(text) RETURNS text LANGUAGE plpgsql IMMUTABLE AS $$BEGIN RETURN $1; END$$; CREATE INDEX fail_rebuild ON sample (index_value(value)); CREATE OR REPLACE FUNCTION index_value(text) RETURNS text LANGUAGE plpgsql IMMUTABLE AS $$BEGIN RAISE EXCEPTION 'synthetic rebuild failure'; END$$;")
	markChanged()
	out, err = prepare()
	require.Error(t, err)
	require.Contains(t, out, "synthetic rebuild failure")
	require.Equal(t, before, index(), "an earlier rebuilt index must roll back")
	require.Equal(t, "proof-old", strings.TrimSpace(p.sql(t, "SELECT datcollversion FROM pg_database WHERE datname='collation_proof';")))
	query("DROP INDEX fail_rebuild; DROP FUNCTION index_value(text); CREATE MATERIALIZED VIEW unsupported AS TABLE sample;")
	out, err = prepare()
	require.Error(t, err)
	require.Contains(t, out, "collation change requires a separately reviewed data migration")
	require.Equal(t, before, index())
}
