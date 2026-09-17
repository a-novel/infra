package tests_test

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/a-novel/infra/internal/release"
)

type releaseFixture struct {
	*sandbox
	compiler                  *release.Compiler
	files                     []string
	identity                  release.Identity
	manifest, config, receipt object
}

func compiledFixture(t *testing.T) *releaseFixture {
	t.Helper()
	f := &releaseFixture{sandbox: setup(t)}
	var err error
	f.compiler, err = release.NewCompiler()
	require.NoError(t, err)
	f.manifest = fixtureYAML[object](t, []byte(read(t, filepath.Join(f.root, "tests/fixtures/manifests/valid.yaml"))))
	f.config = readJSON(t, filepath.Join(f.root, "tests/fixtures/release-config.json"))
	for index, key := range []string{
		"authentication_postgres_password", "authentication_postgres_backup_password",
		"authentication_smtp_password", "authentication_super_admin_password",
		"json_keys_postgres_password", "json_keys_postgres_backup_password", "json_keys_app_master_key",
	} {
		nested(f.config, "secret_versions")[key] = index + 1
	}
	f.identity = release.Identity{Commit: strings.Repeat("a", 40), RunID: "123", RunAttempt: 1, Nonce: "first"}
	f.files = []string{filepath.Join(f.dir, "images.yaml"), filepath.Join(f.dir, "config.json"), "-", filepath.Join(f.dir, "first")}
	f.compile(t)
	operations := object{"executions": object{}, "initialization": nil, "health": object{"jsonKeys": "passed", "authentication": "passed"}}
	for _, key := range []string{
		"jsonKeysMigrations", "jsonKeysRotation", "authenticationMigrations",
		"postgresBackupJsonKeys", "postgresBackupAuthentication",
		"postgresRestoreJsonKeys", "postgresRestoreAuthentication", "postgresBackupMonitor",
	} {
		nested(operations, "executions")[key] = nil
	}
	writeJSON(t, filepath.Join(f.dir, "operations.json"), operations)
	f.files[2] = filepath.Join(f.dir, "receipt.json")
	require.NoError(t, f.compiler.BuildReceipt([]string{
		"deployment", filepath.Join(f.files[3], "release.json"),
		filepath.Join(f.files[3], "active.tfvars.json"), filepath.Join(f.dir, "operations.json"), f.files[2],
	}, time.Date(2026, 9, 17, 12, 0, 0, 0, time.UTC)))
	f.receipt = readJSON(t, f.files[2])
	f.identity = release.Identity{Commit: strings.Repeat("b", 40), RunID: "124", RunAttempt: 1, Nonce: "next"}
	f.files[3] = filepath.Join(f.dir, "next")
	return f
}

func (f *releaseFixture) compile(t *testing.T) object {
	t.Helper()
	writeJSON(t, f.files[0], f.manifest)
	writeJSON(t, f.files[1], f.config)
	if f.receipt != nil {
		writeJSON(t, f.files[2], f.receipt)
	}
	require.NoError(t, f.compiler.CompileRelease(f.files, f.identity, "deploy", "", ""))
	return readJSON(t, filepath.Join(f.files[3], "release.json"))
}

func (f *releaseFixture) change(service string, database bool) {
	for slot, value := range nested(f.manifest, "components", "service-"+strings.ReplaceAll(service, "_", "-"), "images") {
		image := value.(object)
		image["tag"] = "v4.0.0"
		if slot != "database" || database {
			image["digest"] = "sha256:3" + image["digest"].(string)[8:]
		}
	}
}

func (f *releaseFixture) driver(t *testing.T, step string, calls []invocation) {
	t.Helper()
	require.NoError(t, os.WriteFile(filepath.Join(f.dir, "driver.sh"), []byte(read(t, filepath.Join(f.root, "ops/google-release-driver.sh"))), 0o600))
	for _, name := range []string{"gcloud", "infra", "create-reviewed-plan.sh", "apply-reviewed-plan.sh", "config-custody.sh", "restore-database-release.sh", "receipt-custody.sh"} {
		f.command(t, name)
	}
	f.env["RELEASE_DIRECTORY"], f.env["STATE_BUCKET"], f.env["RECEIPT_BUCKET"] = f.files[3], "fixture-state", "fixture-receipts"
	f.env["GITHUB_SHA"], f.env["GITHUB_RUN_ID"], f.env["GITHUB_RUN_ATTEMPT"] = f.identity.Commit, f.identity.RunID, "1"
	f.expect(t, calls)
	code, out := f.run(t, "bash", filepath.Join(f.dir, "driver.sh"), step)
	expectCode(t, 0, code, out)
	require.JSONEq(t, "[]", read(t, f.env["INFRA_TEST_SEQUENCE"]))
}

type invocation struct {
	Name   string
	Args   []string
	Output string `json:",omitempty"`
	Code   int    `json:",omitempty"`
	Body   string `json:",omitempty"`
}

func (f *sandbox) expect(t *testing.T, calls []invocation) {
	t.Helper()
	f.env["INFRA_TEST_SEQUENCE"] = filepath.Join(f.dir, "expected.json")
	writeJSON(t, f.env["INFRA_TEST_SEQUENCE"], calls)
}

func jsonText(t *testing.T, value any) string {
	t.Helper()
	data, err := json.Marshal(value)
	require.NoError(t, err)
	return string(data)
}
