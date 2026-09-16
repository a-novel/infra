package release_test

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"go.yaml.in/yaml/v3"

	"github.com/a-novel/infra/internal/release"
)

type object = map[string]any

type fixture struct {
	compiler                  *release.Compiler
	files                     []string
	identity                  release.Identity
	manifest, config, receipt object
	first                     string
}

func field(value any, path ...string) any {
	for _, key := range path {
		value = value.(object)[key]
	}
	return value
}

func section(value any, path ...string) object { return field(value, path...).(object) }

func write(t *testing.T, path string, value any) {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		panic(err)
	}
	if err = os.WriteFile(path, data, 0o600); err != nil {
		panic(err)
	}
}

func read(t *testing.T, path string) object {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		panic(err)
	}
	var result object
	if err = yaml.Unmarshal(data, &result); err != nil {
		panic(err)
	}
	// Decode all fixture numbers consistently with JSON output.
	encoded, err := json.Marshal(result)
	if err != nil {
		panic(err)
	}
	decoder := json.NewDecoder(bytes.NewReader(encoded))
	decoder.UseNumber()
	if err = decoder.Decode(&result); err != nil {
		panic(err)
	}
	return result
}

func setup(t *testing.T) *fixture {
	t.Helper()
	compiler, err := release.NewCompiler()
	if err != nil {
		panic(err)
	}
	directory := t.TempDir()
	fixture := &fixture{
		compiler: compiler,
		files:    []string{filepath.Join(directory, "images.yaml"), filepath.Join(directory, "config.json"), "-", filepath.Join(directory, "first")},
		identity: release.Identity{Commit: strings.Repeat("a", 40), RunID: "123", RunAttempt: 1, Nonce: "first"},
		manifest: read(t, "../../tests/fixtures/manifests/valid.yaml"), config: read(t, "../../tests/fixtures/release-config.json"),
	}
	for index, key := range []string{"authentication_postgres_password", "authentication_postgres_backup_password", "authentication_smtp_password", "authentication_super_admin_password", "json_keys_postgres_password", "json_keys_postgres_backup_password", "json_keys_app_master_key"} {
		section(fixture.config, "secret_versions")[key] = index + 1
	}
	if err = fixture.compile(t, "deploy", "", ""); err != nil {
		panic(err)
	}
	fixture.first = fixture.files[3]
	operations := object{"executions": object{}, "initialization": nil, "health": object{"jsonKeys": "passed", "authentication": "passed"}}
	for _, key := range []string{"jsonKeysMigrations", "jsonKeysRotation", "authenticationMigrations", "postgresBackupJsonKeys", "postgresBackupAuthentication", "postgresRestoreJsonKeys", "postgresRestoreAuthentication", "postgresBackupMonitor"} {
		section(operations, "executions")[key] = nil
	}
	operationsPath := filepath.Join(directory, "operations.json")
	write(t, operationsPath, operations)
	fixture.files[2] = filepath.Join(directory, "receipt.json")
	if err = compiler.BuildReceipt([]string{"deployment", filepath.Join(fixture.first, "release.json"), filepath.Join(fixture.first, "active.tfvars.json"), operationsPath, fixture.files[2]}, time.Date(2026, 9, 16, 12, 0, 0, 0, time.UTC)); err != nil {
		panic(err)
	}
	fixture.receipt = read(t, fixture.files[2])
	fixture.identity = release.Identity{Commit: strings.Repeat("b", 40), RunID: "124", RunAttempt: 1, Nonce: "next"}
	fixture.files[3] = filepath.Join(directory, "next")
	return fixture
}

func (fixture *fixture) compile(t *testing.T, action, prior, current string) error {
	t.Helper()
	write(t, fixture.files[0], fixture.manifest)
	write(t, fixture.files[1], fixture.config)
	if fixture.receipt != nil {
		write(t, fixture.files[2], fixture.receipt)
	}
	return fixture.compiler.CompileRelease(fixture.files, fixture.identity, action, prior, current)
}

func (fixture *fixture) change(service string, database bool) {
	for slot, value := range section(fixture.manifest, "components", "service-"+strings.ReplaceAll(service, "_", "-"), "images") {
		image := value.(object)
		image["tag"] = "v4.0.0"
		if slot != "database" || database {
			image["digest"] = "sha256:3" + image["digest"].(string)[8:]
		}
	}
}

func result(t *testing.T, fixture *fixture, file string) object {
	t.Helper()
	return read(t, filepath.Join(fixture.files[3], file))
}
