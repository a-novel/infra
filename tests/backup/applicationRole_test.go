package backup_test

import (
	"os"
	"os/exec"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

// TestApplicationRoleConvergence executes the shipped SQL against a disposable database. Each case
// leaves the database as a boot can find it; convergence must restore the same safe role.
func TestApplicationRoleConvergence(t *testing.T) {
	if os.Getenv("BACKUP_TEST") != "1" {
		t.Skip("run inside builds/backup-test.Dockerfile")
	}
	asset, err := os.ReadFile("/database-startup.sh")
	require.NoError(t, err)
	_, sql, found := strings.Cut(string(asset), "<<'APPLICATION_ROLE'\n")
	require.True(t, found)
	sql, _, found = strings.Cut(sql, "\nAPPLICATION_ROLE\n")
	require.True(t, found)
	p := newProof(t, "application")
	p.sql(t, "CREATE DATABASE agora_proof;")
	psql := func(statement string, args ...string) (string, error) {
		cmd := exec.CommandContext(t.Context(), "psql", append([]string{"-XqAt", "-h", p.root, "-d", "agora_proof", "-v", "ON_ERROR_STOP=1"}, args...)...)
		cmd.Stdin = strings.NewReader(statement)
		out, err := cmd.CombinedOutput()
		return strings.TrimSpace(string(out)), err
	}
	query := func(statement string) string {
		t.Helper()
		out, err := psql(statement)
		require.NoError(t, err, out)
		return out
	}
	// The objects a service's migrations and its database image create, as the bootstrap superuser.
	query(`CREATE EXTENSION "uuid-ossp";
CREATE TYPE status AS ENUM ('open', 'closed');
CREATE DOMAIN label AS text CHECK (VALUE <> '');
CREATE TABLE items (id bigserial PRIMARY KEY, code bigint GENERATED ALWAYS AS IDENTITY, name label NOT NULL, status status NOT NULL);
CREATE VIEW open_items AS SELECT * FROM items WHERE status = 'open';
CREATE SEQUENCE tickets;
CREATE FUNCTION item_count() RETURNS bigint LANGUAGE sql AS 'SELECT count(*) FROM items';
CREATE TABLE events (at date NOT NULL) PARTITION BY RANGE (at);
CREATE TABLE events_2026 PARTITION OF events FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');
CREATE TABLE bun_migrations (id bigserial PRIMARY KEY, name text NOT NULL);`)

	for _, tc := range []struct{ name, before string }{
		{name: "first boot"},
		{name: "unchanged"},
		{name: "privilege drift", before: "ALTER ROLE agora_proof_app SUPERUSER CREATEDB CREATEROLE REPLICATION BYPASSRLS NOLOGIN;"},
		{name: "superuser migration", before: "CREATE TABLE later (id uuid PRIMARY KEY DEFAULT uuid_generate_v4()); CREATE FUNCTION later_count() RETURNS bigint LANGUAGE sql AS 'SELECT 1';"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if tc.before != "" {
				query(tc.before)
			}
			out, err := psql(sql, "--single-transaction")
			require.NoError(t, err, out)

			require.Equal(t, "t|f|f|f|f|f", query(`SELECT rolcanlogin, rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls
FROM pg_roles WHERE rolname = 'agora_proof_app';`))
			require.Equal(t, "agora_proof_app", query("SELECT nspowner::regrole FROM pg_namespace WHERE nspname = 'public';"))
			require.Empty(t, query(`SELECT string_agg(name, ',' ORDER BY name) FROM (
    SELECT relname::text AS name, relowner AS owner, 'pg_class'::regclass AS classid, oid FROM pg_class WHERE relnamespace = 'public'::regnamespace
    UNION ALL SELECT proname, proowner, 'pg_proc'::regclass, oid FROM pg_proc WHERE pronamespace = 'public'::regnamespace
    UNION ALL SELECT typname, typowner, 'pg_type'::regclass, oid FROM pg_type WHERE typnamespace = 'public'::regnamespace
) object
WHERE owner <> 'agora_proof_app'::regrole
  AND NOT EXISTS (SELECT FROM pg_depend WHERE classid = object.classid AND objid = object.oid AND deptype = 'e');`), "every object outside an extension must belong to the role")
			require.Equal(t, "postgres", query("SELECT proowner::regrole FROM pg_proc WHERE proname = 'uuid_generate_v4';"), "extension members must stay with the extension")

			// The role runs migrations, but it cannot reach a shell or raise its own privileges.
			query(`BEGIN;
SET LOCAL ROLE agora_proof_app;
ALTER TABLE items ADD COLUMN note text;
CREATE TABLE extra (id uuid PRIMARY KEY DEFAULT uuid_generate_v4());
SELECT nextval('tickets'), nextval('items_id_seq');
ROLLBACK;`)
			for _, escalation := range []string{
				"COPY (SELECT 1) TO PROGRAM 'true';",
				"ALTER ROLE agora_proof_app SUPERUSER;",
			} {
				out, err := psql("SET ROLE agora_proof_app; " + escalation)
				require.Error(t, err, escalation)
				require.Contains(t, out, "permission denied", escalation)
			}
		})
	}
}
