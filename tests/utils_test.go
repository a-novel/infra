package tests_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"go.yaml.in/yaml/v3"
)

type object = map[string]any

const privateValue = "fixture-private-value"

// sandbox gives shell entry points an isolated environment and an allowlisted PATH.
// Cloud clients are absent unless a test installs a local fake explicitly.
type sandbox struct {
	dir, bin, root string
	env            map[string]string
}

func setup(t *testing.T) *sandbox {
	t.Helper()
	dir := t.TempDir()
	root, err := filepath.Abs("..")
	require.NoError(t, err)
	f := &sandbox{dir: dir, bin: filepath.Join(dir, "bin"), root: root}
	require.NoError(t, os.Mkdir(f.bin, 0o700))
	f.env = map[string]string{
		"PATH": f.bin, "HOME": dir, "TMPDIR": dir, "LC_ALL": "C",
		"GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.DevNull,
	}
	for _, name := range []string{"bash", "sh", "jq", "dirname", "mktemp", "mkdir", "rm", "chmod", "cat", "cp", "mv", "find", "sort", "grep"} {
		path, err := exec.LookPath(name)
		require.NoError(t, err)
		f.link(t, name, path)
	}
	return f
}

func (f *sandbox) link(t *testing.T, name, source string) {
	t.Helper()
	require.NoError(t, os.Symlink(source, filepath.Join(f.bin, name)))
}

func (f *sandbox) fake(t *testing.T, name, fixture string) {
	t.Helper()
	f.link(t, name, filepath.Join(f.root, "tests", "fixtures", fixture))
}

func (f *sandbox) run(t *testing.T, name string, args ...string) (int, string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(t.Context(), 15*time.Second)
	defer cancel()
	if !filepath.IsAbs(name) {
		name = filepath.Join(f.bin, name)
	}
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Dir, cmd.WaitDelay = f.root, time.Second
	for key, value := range f.env {
		cmd.Env = append(cmd.Env, key+"="+value)
	}
	out, err := cmd.CombinedOutput()
	require.NoError(t, ctx.Err(), "command timed out: %s", out)
	require.NoFileExists(t, filepath.Join(f.dir, "unexpected"), "unexpected fake command: %s", out)
	code := 0
	if err != nil {
		var exit *exec.ExitError
		require.ErrorAs(t, err, &exit, "%s", out)
		code = exit.ExitCode()
	}
	return code, string(out)
}

func (f *sandbox) script(t *testing.T, name string, args ...string) (int, string) {
	t.Helper()
	return f.run(t, "bash", append([]string{filepath.Join(f.root, "ops", name+".sh")}, args...)...)
}

func writeJSON(t *testing.T, path string, value any) {
	t.Helper()
	data, err := json.Marshal(value)
	require.NoError(t, err)
	require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o700))
	require.NoError(t, os.WriteFile(path, data, 0o600))
}

func read(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	require.NoError(t, err)
	return string(data)
}

func readJSON(t *testing.T, path string) object {
	t.Helper()
	var value object
	require.NoError(t, json.Unmarshal([]byte(read(t, path)), &value))
	return value
}

func fixtureYAML[T any](t *testing.T, data []byte) T {
	t.Helper()
	var value T
	decoder := yaml.NewDecoder(bytes.NewReader(data))
	decoder.KnownFields(true)
	require.NoError(t, decoder.Decode(&value))
	return value
}

func expectCode(t *testing.T, expected, code int, output string) {
	t.Helper()
	require.Equal(t, expected, code, "%s", output)
	require.NotContains(t, output, privateValue)
}

func nested(value object, keys ...string) object {
	for _, key := range keys {
		value = value[key].(object)
	}
	return value
}

// TestMain also supplies the small command fakes used by the driver/probe tests.
func TestMain(m *testing.M) {
	if os.Getenv("INFRA_TEST_COMMAND") == "1" {
		code, err := fixtureCommand(filepath.Base(os.Args[0]), os.Args[1:])
		if err != nil {
			if writeErr := os.WriteFile(filepath.Join(os.Getenv("TMPDIR"), "unexpected"), []byte(err.Error()), 0o600); writeErr != nil {
				panic(errors.Join(err, writeErr))
			}
			code = 99
		}
		os.Exit(code)
	}
	os.Exit(m.Run())
}
