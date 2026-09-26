package tests_test

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"go.yaml.in/yaml/v3"
)

func TestRenovatePolicy(t *testing.T) {
	t.Parallel()
	config := readJSON(t, "../renovate.json")
	require.NotEqual(t, true, config["automerge"])
	rules := config["packageRules"].([]any)
	for _, service := range []string{"service-json-keys", "service-authentication"} {
		t.Run(service, func(t *testing.T) {
			t.Parallel()
			var matches []object
			for _, value := range rules {
				rule := value.(object)
				if rule["groupName"] == service+" images" {
					matches = append(matches, rule)
				}
			}
			require.Len(t, matches, 1)
			rule := matches[0]
			expected := object{
				"matchDatasources": []any{"docker"}, "matchFileNames": []any{"deploy/production/images.yaml"},
				"matchPackageNames": []any{"ghcr.io/a-novel/" + service + "/**"}, "minimumGroupSize": float64(4),
				"groupSlug": service + "-images", "separateMajorMinor": true,
			}
			for key, value := range expected {
				require.Equal(t, value, rule[key], "%s", key)
			}
		})
	}
	for _, testCase := range []struct{ key, value string }{
		{"matchFileNames", "deploy/production/images.yaml"},
		{"matchPackageNames", "opentofu/opentofu"},
	} {
		found := false
		for _, value := range rules {
			rule := value.(object)
			if values, ok := rule[testCase.key].([]any); ok && slices.Contains(values, any(testCase.value)) && rule["automerge"] == false {
				found = true
			}
		}
		require.True(t, found, "manual review for %s", testCase.value)
	}
	// The final rule must override any generic automation rule for these paths.
	last := rules[len(rules)-1].(object)
	require.Equal(t, false, last["automerge"])
	require.ElementsMatch(t, []any{"bootstrap/**", "environments/production/**", "deploy/production/**", "**/*.tf", "**/*.tf.json", "**/*.tofu", "**/*.tofu.json", "**/.terraform.lock.hcl"}, last["matchFileNames"])
}

func TestRenovateLookup(t *testing.T) {
	t.Parallel()
	f := setup(t)
	for _, name := range []string{"node", "git"} {
		path, err := exec.LookPath(name)
		require.NoError(t, err)
		f.link(t, name, path)
	}
	server := httptest.NewServer(http.HandlerFunc(registryResponse))
	t.Cleanup(server.Close)
	registry := strings.TrimPrefix(server.URL, "http://")
	config := readJSON(t, "../renovate.json")
	const workflowFile = ".github/workflows/main.yaml"
	files := []string{workflowFile, "go.mod", "golangci-lint.mod"}
	config["enabledManagers"] = []string{"custom.regex", "gomod"}
	config["includePaths"] = append([]string{"deploy/production/images.yaml"}, files...)
	config["onboarding"], config["requireConfig"], config["fetchChangeLogs"] = false, "required", "off"
	config["hostRules"] = []object{{"hostType": "docker", "matchHost": registry, "insecureRegistry": true}}
	rules := config["packageRules"].([]any)
	for _, value := range rules {
		rule := value.(object)
		names, _ := rule["matchPackageNames"].([]any)
		for index, name := range names {
			names[index] = strings.ReplaceAll(name.(string), "ghcr.io/a-novel/", registry+"/a-novel/")
		}
	}
	// Extract tool pins without looking up their remote release hosts.
	config["packageRules"] = append(rules, object{"matchFileNames": files, "enabled": false})
	writeJSON(t, filepath.Join(f.dir, "renovate.json"), config)
	for _, file := range files {
		destination := filepath.Join(f.dir, file)
		require.NoError(t, os.MkdirAll(filepath.Dir(destination), 0o700))
		require.NoError(t, os.WriteFile(destination, []byte(read(t, "../"+file)), 0o600))
	}
	// Struct field order preserves the repository/tag regex-manager contract.
	var manifest struct {
		SchemaVersion int `yaml:"schemaVersion"`
		PostgresMajor int `yaml:"postgresMajor"`
		Components    map[string]struct {
			Enabled bool
			Images  map[string]struct{ Repository, Tag string }
		}
	}
	require.NoError(t, yaml.Unmarshal([]byte(read(t, "../deploy/production/images.yaml")), &manifest))
	for _, component := range manifest.Components {
		for slot, image := range component.Images {
			repository := strings.TrimPrefix(image.Repository, "ghcr.io/")
			image.Repository, image.Tag = registry+"/"+repository, "v2.5.0"
			component.Images[slot] = image
		}
	}
	manifestBytes, err := yaml.Marshal(manifest)
	require.NoError(t, err)
	manifestPath := filepath.Join(f.dir, "deploy/production/images.yaml")
	require.NoError(t, os.MkdirAll(filepath.Dir(manifestPath), 0o700))
	require.NoError(t, os.WriteFile(manifestPath, manifestBytes, 0o600))
	binary := filepath.Join(f.root, "node_modules/.bin/renovate")
	f.root = f.dir
	for _, args := range [][]string{
		{"init", "--quiet", "--initial-branch=master"},
		{"add", "renovate.json", "deploy", ".github", "go.mod", "golangci-lint.mod"},
		{"-c", "user.name=Renovate fixture", "-c", "user.email=fixture@example.invalid", "commit", "--quiet", "-m", "test: fixture"},
	} {
		code, output := f.run(t, "git", args...)
		expectCode(t, 0, code, output)
	}
	f.env["LOG_FORMAT"], f.env["LOG_LEVEL"] = "json", "debug"
	f.env["RENOVATE_BASE_DIR"], f.env["RENOVATE_CACHE_DIR"] = filepath.Join(f.dir, "base"), filepath.Join(f.dir, "cache")
	f.env["RENOVATE_REPOSITORY_CACHE"] = "disabled"
	ctx, cancel := context.WithTimeout(t.Context(), 90*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, binary, "--platform=local", "--dry-run=lookup")
	cmd.Dir, cmd.WaitDelay = f.dir, time.Second
	for key, value := range f.env {
		cmd.Env = append(cmd.Env, key+"="+value)
	}
	output, runErr := cmd.CombinedOutput()
	require.NoError(t, ctx.Err(), "%s", output)
	var packages map[string][]struct {
		PackageFile string
		Deps        []struct {
			DepName, Datasource, CurrentValue string
			Updates                           []struct{ BranchName, NewValue, UpdateType string }
		}
	}
	var loggerErrors []string
	for line := range strings.SplitSeq(string(output), "\n") {
		var record struct {
			Msg          string
			Config       json.RawMessage
			LoggerErrors []struct{ Msg string }
		}
		if json.Unmarshal([]byte(line), &record) != nil {
			continue
		}
		if record.Msg == "packageFiles with updates" {
			require.NoError(t, json.Unmarshal(record.Config, &packages))
		}
		for _, entry := range record.LoggerErrors {
			loggerErrors = append(loggerErrors, entry.Msg)
		}
	}
	// Local developer Node may be newer than Renovate supports; all other errors fail.
	if runErr != nil {
		require.NotEmpty(t, loggerErrors, "%s", output)
		for _, message := range loggerErrors {
			require.Equal(t, "Unsupported node environment detected. Please update your node version.", message, "%s", output)
		}
	}
	require.NotEmpty(t, packages, "%s", output)
	for file, dependency := range map[string]string{"go.mod": "github.com/stretchr/testify", "golangci-lint.mod": "github.com/golangci/golangci-lint/v2"} {
		var extracted []string
		for _, module := range packages["gomod"] {
			if module.PackageFile == file {
				for _, dep := range module.Deps {
					extracted = append(extracted, dep.DepName)
					require.Empty(t, dep.Updates)
				}
			}
		}
		require.Contains(t, extracted, dependency)
	}
	var extracted []string
	groups := map[string][]string{}
	for _, file := range packages["regex"] {
		for _, dep := range file.Deps {
			if file.PackageFile == workflowFile {
				extracted = append(extracted, dep.Datasource+" "+dep.DepName+" "+dep.CurrentValue)
				require.Empty(t, dep.Updates)
			}
			for _, update := range dep.Updates {
				groups[update.BranchName] = append(groups[update.BranchName], update.UpdateType+":"+update.NewValue)
				require.NotEqual(t, "digest", update.UpdateType)
			}
		}
	}
	annotations := regexp.MustCompile(`# renovate: datasource=(\S+) depName=(\S+)\s+\w+:\s*["']?(v?\d+\.\d+\.\d+)`).FindAllStringSubmatch(read(t, "../"+workflowFile), -1)
	require.NotEmpty(t, annotations)
	for _, annotation := range annotations {
		require.Contains(t, extracted, strings.Join(annotation[1:], " "))
	}
	// Lookup does not create PRs; minimum group size is checked in TestRenovatePolicy.
	require.Equal(t, map[string][]string{
		"renovate/service-json-keys-images":       {"minor:v2.6.0", "minor:v2.6.0", "minor:v2.6.0", "minor:v2.6.0"},
		"renovate/major-service-json-keys-images": {"major:v3.0.0", "major:v3.0.0", "major:v3.0.0", "major:v3.0.0"},
	}, groups)
}

func registryDigest(repository, reference string) string {
	return fmt.Sprintf("sha256:%x", sha256.Sum256([]byte(repository+":"+reference)))
}

func registryResponse(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	if r.URL.Path == "/v2/" {
		_, _ = fmt.Fprint(w, "{}")
		return
	}
	repository := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/v2/"), "/tags/list")
	if before, _, ok := strings.Cut(repository, "/manifests/"); ok {
		repository = before
	}
	tags := []string{"latest", "master", "feat-key-rotation", "pr-123", strings.Repeat("a", 40), "v2", "v2.5", "v2.6.0-rc.1", "v2.5.0"}
	if strings.HasPrefix(repository, "a-novel/service-json-keys/") {
		tags = append(tags, "v2.6.0", "v3.0.0")
	}
	var body any
	if strings.HasSuffix(r.URL.Path, "/tags/list") {
		body = object{"name": repository, "tags": tags}
	} else if _, reference, ok := strings.Cut(r.URL.Path, "/manifests/"); ok && (strings.HasPrefix(reference, "sha256:") || slices.Contains(tags, reference)) {
		digest := registryDigest(repository, reference)
		w.Header().Set("Content-Type", "application/vnd.oci.image.manifest.v1+json")
		if repository == "a-novel/service-authentication/rest" && reference == "v2.5.0" {
			digest = registryDigest(repository, "mutated-v2.5.0")
		} else if strings.HasPrefix(reference, "sha256:") {
			digest = reference
			w.Header().Set("Content-Type", "application/vnd.oci.image.index.v1+json")
		}
		w.Header().Set("Docker-Content-Digest", digest)
		body = object{
			"schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json",
			"config": object{"mediaType": "application/vnd.oci.image.config.v1+json", "digest": registryDigest(repository, "config"), "size": 2}, "layers": []any{},
			"annotations": object{"org.opencontainers.image.source": "https://github.com/" + strings.Join(strings.Split(repository, "/")[:2], "/"), "org.opencontainers.image.revision": strings.Repeat("a", 40)},
		}
	} else {
		w.WriteHeader(http.StatusNotFound)
		body = object{"errors": []object{{"code": "MANIFEST_UNKNOWN"}}}
	}
	if r.Method != http.MethodHead {
		_ = json.NewEncoder(w).Encode(body)
	}
}
