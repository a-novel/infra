package artifact_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"go.yaml.in/yaml/v3"

	"github.com/a-novel/infra/internal/artifact"
	"github.com/a-novel/infra/internal/release"
)

type object = map[string]any

func read(t *testing.T, path string) object {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		panic(err)
	}
	var value object
	if err = yaml.Unmarshal(data, &value); err != nil {
		panic(err)
	}
	return value
}

func write(t *testing.T, value any) string {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		panic(err)
	}
	path := filepath.Join(t.TempDir(), "input.json")
	if err = os.WriteFile(path, data, 0o600); err != nil {
		panic(err)
	}
	return path
}

func images(manifest object, service string) object {
	return manifest["components"].(object)["service-"+service].(object)["images"].(object)
}

func serviceInputs(manifest object, service string) object {
	jobs, secrets := object{}, object{"postgres-password": 2}
	roles := []string{"migrations"}
	if service == "json-keys" {
		roles, secrets["app-master-key"] = append(roles, "rotatekeys"), 7
	}
	for _, role := range roles {
		jobs[role] = "europe-west1-docker.pkg.dev/fixture-service/agora-production/service-" + service + "/jobs/" + role + "@" +
			images(manifest, service)["jobs/"+role].(object)["digest"].(string)
	}
	return object{"service": service, "project_id": "fixture-service", "management_project_id": "fixture-management", "region": "europe-west1", "images": jobs, "secret_versions": secrets}
}

func compiledRelease(t *testing.T, manifest object) object {
	t.Helper()
	compiler, err := release.NewCompiler()
	if err != nil {
		panic(err)
	}
	directory := t.TempDir()
	if err = compiler.CompileRelease([]string{write(t, manifest), "../../tests/fixtures/release-config.json", "-", directory},
		release.Identity{Commit: strings.Repeat("a", 40), RunID: "123", RunAttempt: 1, Nonce: "fixture"}, "deploy", "", ""); err != nil {
		panic(err)
	}
	return read(t, filepath.Join(directory, "release.json"))
}

type call struct {
	name   string
	args   []string
	output string
	fail   bool
}

func imageCalls(manifest object, service string) []call {
	var calls []call
	for _, family := range []struct {
		service string
		slots   []string
	}{
		{"json-keys", []string{"database", "grpc", "jobs/migrations", "jobs/rotatekeys"}},
		{"authentication", []string{"database", "jobs/init", "jobs/migrations", "rest"}},
	} {
		if service != "" && service != family.service {
			continue
		}
		for _, slot := range family.slots {
			image := images(manifest, family.service)[slot].(object)
			repository, digest := image["repository"].(string), image["digest"].(string)
			producer := "a-novel/service-" + family.service
			calls = append(calls,
				call{"gh", []string{"attestation", "verify", "oci://" + repository + "@" + digest, "--repo", producer, "--signer-workflow", producer + "/.github/workflows/release.yaml", "--source-ref", "refs/heads/master", "--deny-self-hosted-runners"}, "private-diagnostic", false},
				call{"registry", []string{repository + ":" + image["tag"].(string), digest, slot}, "", false})
		}
	}
	return calls
}

type testRegistry struct {
	execute func(context.Context, io.Writer, string, ...string) error
}

func (registry testRegistry) Resolve(ctx context.Context, reference string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, time.Minute)
	defer cancel()
	var output strings.Builder
	if err := registry.execute(ctx, &output, "resolve", reference); err != nil {
		return "", errors.New("image version unavailable")
	}
	return output.String(), nil
}

func (registry testRegistry) Verify(ctx context.Context, image release.SourceImage) error {
	if err := registry.execute(ctx, io.Discard, "registry", image.Repository+":"+image.Tag, image.Digest, image.Slot); err != nil {
		return errors.New("image evidence unavailable")
	}
	return nil
}

func (registry testRegistry) Copy(ctx context.Context, source, tag string) error {
	if err := registry.execute(ctx, io.Discard, "copy", source, tag); err != nil {
		return errors.New("image copy is unconfirmed")
	}
	return nil
}

// checkCalls never starts a process. Exact expected arguments exclude peer reads,
// payload access and writes; unexpected calls fail independently of the exit code.
func checkCalls(t *testing.T, args []string, calls []call, code int) {
	t.Helper()
	count := 0
	execute := func(ctx context.Context, output io.Writer, name string, args ...string) error {
		require.Less(t, count, len(calls), "unexpected external request")
		expected := calls[count]
		count++
		require.Equal(t, append([]string{expected.name}, expected.args...), append([]string{name}, args...))
		_, bounded := ctx.Deadline()
		if name != "copy" {
			require.True(t, bounded)
		}
		if expected.fail {
			return errors.New("private-diagnostic")
		}
		_, err := io.WriteString(output, expected.output)
		return err
	}
	var output bytes.Buffer
	var got int
	if len(args) > 0 && args[0] == "promote" {
		got = artifact.Promote(t.Context(), args[1:], execute, testRegistry{execute: execute}, &output, &output)
	} else {
		got = artifact.Run(t.Context(), args, execute, testRegistry{execute: execute}, &output, &output)
	}
	require.Equal(t, code, got, output.String())
	require.Equal(t, len(calls), count)
	require.NotContains(t, output.String(), "private-diagnostic")
}
