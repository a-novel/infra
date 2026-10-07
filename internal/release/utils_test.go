package release_test

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"go.yaml.in/yaml/v3"
)

type object = map[string]any

type fixture struct {
	files    []string
	manifest object
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
	file := filepath.Join(t.TempDir(), "images.json")
	f := &fixture{files: []string{file}, manifest: read(t, "../../tests/fixtures/manifests/valid.yaml")}
	write(t, file, f.manifest)
	return f
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
