package backup_test

import (
	"os"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

// TestCollationPreparation executes the shipped SQL against disposable databases.
// Synthetic version markers exercise mismatches without depending on an OS upgrade.
func TestCollationPreparation(t *testing.T) {
	if os.Getenv("BACKUP_TEST") != "1" {
		t.Skip("run inside builds/backup-test.Dockerfile")
	}
	asset, err := os.ReadFile("/database-startup.sh")
	require.NoError(t, err)
	_, sql, found := strings.Cut(string(asset), "<<'COLLATION'\n")
	require.True(t, found)
	_, sql, found = strings.Cut(sql, "SET LOCAL lock_timeout = ")
	require.True(t, found)
	sql, _, found = strings.Cut(sql, "\nSQL\n")
	require.True(t, found)
	sql = "SET LOCAL lock_timeout = " + sql

	const database = "collation_proof"
	p := newProof(t, "collation", "postgres")
	p.query(t, "postgres", "CREATE DATABASE "+database+" LOCALE 'en_US.utf8' TEMPLATE template0;")
	prepare := func() ([]byte, error) { return p.psql(t, database, sql, "--single-transaction").CombinedOutput() }
	p.query(t, database, "CREATE TABLE sample (value text PRIMARY KEY); INSERT INTO sample VALUES ('plain'), ('été'), ('Zebra');")
	p.query(t, database, "CREATE TABLE ids (id uuid PRIMARY KEY); INSERT INTO ids VALUES (gen_random_uuid());")
	index := func() string {
		return p.query(t, database, "SELECT relfilenode FROM pg_class WHERE relname='sample_pkey';")
	}
	uncollated := func() string {
		return p.query(t, database, "SELECT relfilenode FROM pg_class WHERE relname='ids_pkey';")
	}
	before, beforeUncollated := index(), uncollated()

	markChanged := func() {
		p.query(t, "postgres", "UPDATE pg_database SET datcollversion='proof-old' WHERE datname='"+database+"';")
	}
	markChanged()
	out, err := prepare()
	require.NoError(t, err, string(out))
	require.NotEqual(t, before, index())
	require.Equal(t, beforeUncollated, uncollated(), "an index on no collation must not be rebuilt")
	require.Equal(t, "t", p.query(t, database, "SELECT datcollversion=pg_database_collation_actual_version(oid) FROM pg_database WHERE datname=current_database();"))
	require.Equal(t, "3", p.query(t, database, "SELECT count(*) FROM sample;"))

	before = index()
	out, err = prepare()
	require.NoError(t, err, string(out))
	require.Equal(t, before, index(), "unchanged libraries must not rebuild indexes")

	p.query(t, database, "CREATE FUNCTION index_value(text) RETURNS text LANGUAGE plpgsql IMMUTABLE AS $$BEGIN RETURN $1; END$$; CREATE INDEX fail_rebuild ON sample (index_value(value)); CREATE OR REPLACE FUNCTION index_value(text) RETURNS text LANGUAGE plpgsql IMMUTABLE AS $$BEGIN RAISE EXCEPTION 'synthetic rebuild failure'; END$$;")
	markChanged()
	out, err = prepare()
	require.Error(t, err)
	require.Contains(t, string(out), "synthetic rebuild failure")
	require.Equal(t, before, index(), "an earlier rebuilt index must roll back")
	require.Equal(t, "proof-old", p.query(t, "postgres", "SELECT datcollversion FROM pg_database WHERE datname='"+database+"';"))

	p.query(t, database, "DROP INDEX fail_rebuild; DROP FUNCTION index_value(text); CREATE MATERIALIZED VIEW unsupported AS TABLE sample;")
	out, err = prepare()
	require.Error(t, err)
	require.Contains(t, string(out), "collation change requires a separately reviewed data migration")
	require.Equal(t, before, index())
}
