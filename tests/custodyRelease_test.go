package tests_test

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
	"go.yaml.in/yaml/v3"
	"google.golang.org/api/option"

	"github.com/a-novel/infra/internal/custody"
)

func TestCustodyRelease(t *testing.T) {
	t.Parallel()
	for _, service := range []string{"json-keys", "authentication"} {
		for _, fault := range []string{"", "promote", "changed-promotion", "missing-prior", "apply", "converge", "job-denied", "job-token", "job-image", "job-reconciling", "execution-failed", "execution-template", "execution-pending", "api-image", "api-traffic", "health", "rotation-enabled", "rotation-active"} {
			t.Run(service+"/"+fault, func(t *testing.T) {
				t.Parallel()
				if service == "authentication" && strings.HasPrefix(fault, "rotation-") {
					t.Skip("Authentication has no key-rotation schedule")
				}
				project, zone, role := "agora-private-test", "private", "grpc"
				if service == "authentication" {
					project, zone, role = "agora-api-test", "public-api", "rest"
				}
				scope := "workloads/production/" + zone + "/" + project + "/" + service
				f, args, metadataFile := planFixture(t, "service-release", scope)
				f.env["SELECTED_SERVICE"] = service
				f.env["FOUNDATION_CONFIG"], f.env["MANAGEMENT_PROJECT_ID"] = sharedRegistration, "agora-management-test"
				f.env["SERVICE_JOB_BOOTSTRAP_ENABLED"], f.env["GITHUB_REPOSITORY"] = "true", "a-novel/infra"
				f.env["GITHUB_SHA"], f.env["GITHUB_RUN_ID"], f.env["GITHUB_RUN_ATTEMPT"] = args[2], "124", "1"
				migration := "europe-west1-docker.pkg.dev/agora-private-test/agora-" + service + "-private-production/service-" + service + "/jobs/migrations@sha256:" + strings.Repeat("a", 64)
				image := "europe-west1-docker.pkg.dev/" + project + "/agora-" + service + "/api@sha256:" + strings.Repeat("b", 64)
				apiName := "agora-" + service + "-" + role
				config := readJSON(t, args[5])
				config["service"], config["project_id"], config["zone"] = service, project, zone
				config["private_project_id"], config["migration_image"], config["images"] = "agora-private-test", migration, object{}
				config["api"] = object{"image": image, "revision": apiName + "-candidate", "serving_revision": apiName + "-active"}
				if fault == "promote" || fault == "changed-promotion" || fault == "missing-prior" {
					if fault != "missing-prior" {
						writeJSON(t, filepath.Join(f.env["FAKE_GCS_ROOT"], args[0], scope, "release/config/00000000000000000122-00001.tfvars.json"), config)
					}
					nested(config, "api")["serving_revision"] = apiName + "-candidate"
					if fault == "changed-promotion" {
						config["secret_versions"] = object{"postgres-password": 99}
					}
				}
				writeJSON(t, args[5], config)
				meta := readJSON(t, metadataFile)
				meta["inputsSha256"] = fmt.Sprintf("%x", sha256.Sum256([]byte(read(t, args[5]))))
				writeJSON(t, metadataFile, meta)
				applyStorage(t, f, "")
				guard := filepath.Join(f.env["FAKE_GCS_ROOT"], args[0], "foundation/operations/production", service, "operation.json")
				remotePlan := filepath.Join(filepath.Dir(metadataFile), "plan.tfplan")
				var records object
				require.NoError(t, yaml.Unmarshal([]byte(read(t, "fixtures/native-release.yaml")), &records))
				job, execution, api := nested(records, "job"), nested(records, "execution"), nested(records, "api")
				migrationName := "projects/agora-private-test/locations/europe-west1/jobs/agora-" + service + "-migrations"
				token := fmt.Sprintf("%x", sha256.Sum256([]byte(migration)))[:24]
				job["name"], job["runExecutionToken"] = migrationName, token
				nested(job, "template", "template")["containers"] = []any{object{"image": migration}}
				execution["job"], execution["name"] = migrationName, migrationName+"/executions/agora-"+service+"-migrations-"+token
				execution["template"] = nested(job, "template", "template")
				api["name"] = "projects/" + project + "/locations/europe-west1/services/" + apiName
				nested(api, "template")["revision"] = nested(config, "api")["revision"]
				nested(api, "template")["containers"] = []any{object{"image": image}}
				api["trafficStatuses"] = []any{
					object{"revision": nested(config, "api")["serving_revision"], "percent": 100},
					object{"revision": nested(config, "api")["revision"], "percent": 0, "tag": "candidate"},
				}
				switch fault {
				case "job-token":
					job["runExecutionToken"] = "different"
				case "job-image":
					nested(job, "template", "template")["containers"] = []any{object{"image": "different"}}
				case "job-reconciling":
					job["reconciling"] = true
				case "execution-failed":
					execution["succeededCount"], execution["failedCount"] = 0, 1
				case "execution-pending":
					delete(execution, "completionTime")
				case "execution-template":
					execution["template"] = object{}
				case "api-image":
					nested(api, "template")["containers"] = []any{object{"image": "different"}}
				case "api-traffic":
					api["trafficStatuses"] = []any{object{"revision": "peer", "percent": 100}}
				}
				storageURL, err := url.Parse(f.env["TEST_STORAGE_ENDPOINT"])
				require.NoError(t, err)
				apiJSON, err := json.Marshal(nested(config, "api"))
				require.NoError(t, err)
				probeToken := fmt.Sprintf("%x", sha256.Sum256(apiJSON))[:24]
				proxy := httputil.NewSingleHostReverseProxy(storageURL)
				server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					if !strings.HasPrefix(r.URL.Path, "/v") {
						proxy.ServeHTTP(w, r)
						return
					}
					if r.Method != http.MethodGet {
						t.Errorf("native execution must belong to OpenTofu, got %s", r.Method)
						http.Error(w, privateValue, http.StatusBadRequest)
						return
					}
					var result any
					switch {
					case strings.HasSuffix(r.URL.Path, "/jobs/agora-json-keys-rotation"):
						state := "PAUSED"
						if fault == "rotation-enabled" {
							state = "ENABLED"
						}
						result = object{"state": state}
					case strings.HasSuffix(r.URL.Path, "/jobs/agora-json-keys-rotatekeys/executions"):
						result = object{"executions": []any{}}
						if fault == "rotation-active" {
							result = object{"executions": []any{object{"runningCount": 1}}}
						}
					case r.URL.Path == "/v2/"+migrationName:
						if fault == "job-denied" {
							http.Error(w, privateValue, http.StatusForbidden)
							return
						}
						result = job
					case r.URL.Path == "/v2/"+execution["name"].(string):
						result = execution
					case r.URL.Path == "/v2/"+api["name"].(string):
						result = api
					case strings.Contains(r.URL.Path, "/jobs/agora-json-keys-smoke"):
						suffix := probeToken
						name := "projects/agora-private-test/locations/europe-west1/jobs/agora-json-keys-smoke"
						template := object{"containers": []any{object{"image": image}}}
						if strings.Contains(r.URL.Path, "/executions/") {
							result = object{
								"name": name + "/executions/agora-json-keys-smoke-" + suffix, "job": name, "uid": "probe-execution",
								"completionTime": "2026-10-05T10:00:00Z", "taskCount": 1, "parallelism": 1, "succeededCount": 1, "template": template,
								"conditions": []any{object{"type": "Completed", "state": "CONDITION_SUCCEEDED"}},
							}
							if fault == "health" {
								result.(object)["failedCount"] = 1
							}
						} else {
							result = object{
								"name": name, "uid": "probe-job", "generation": "2", "observedGeneration": "2", "runExecutionToken": suffix,
								"terminalCondition": object{"state": "CONDITION_SUCCEEDED"}, "template": object{"template": template},
							}
						}
					default:
						t.Errorf("unexpected native read: %s", r.URL.Path)
						http.NotFound(w, r)
						return
					}
					w.Header().Set("Content-Type", "application/json")
					if err := json.NewEncoder(w).Encode(result); err != nil {
						t.Error(err)
					}
				}))
				t.Cleanup(server.Close)
				var events []string
				execute := func(ctx context.Context, output io.Writer, command string, values ...string) error {
					if command == "env" {
						at := slices.Index(values, "./ops/tofu-gate.sh")
						require.NotEqual(t, -1, at)
						action := values[at+1]
						require.FileExists(t, guard)
						require.NoFileExists(t, remotePlan)
						events = append(events, action)
						if fault == action {
							return errors.New(privateValue)
						}
						return nil
					}
					if command == "infra" {
						require.Equal(t, []string{"check-health", "candidate"}, values[:2])
						require.FileExists(t, guard)
						want := "https://candidate---fixture-ew.a.run.app"
						if fault == "promote" {
							want = "https://fixture-ew.a.run.app"
						}
						require.Equal(t, want, values[2])
						events = append(events, "health")
						if fault == "health" {
							return errors.New(privateValue)
						}
						return nil
					}
					require.Equal(t, "gcloud", command)
					require.Equal(t, "storage", values[0])
					cmd := exec.CommandContext(ctx, filepath.Join(f.bin, command), values...)
					cmd.Stdout, cmd.Stderr = output, output
					for key, value := range f.env {
						cmd.Env = append(cmd.Env, key+"="+value)
					}
					return cmd.Run()
				}
				var out bytes.Buffer
				code := custody.Run(t.Context(), []string{"plan", "apply", args[0], args[1], args[2], args[3], args[5]},
					func(key string) string { return f.env[key] }, execute, &out, &out,
					option.WithEndpoint(server.URL+"/"), option.WithoutAuthentication())
				require.NotContains(t, out.String(), privateValue)
				if fault == "" || fault == "promote" {
					require.Zero(t, code, out.String())
					require.NoFileExists(t, guard)
					require.Equal(t, []string{"apply", "converge"}, events[:2])
					receipt := readJSON(t, filepath.Join(f.env["FAKE_GCS_ROOT"], "agora-management-test-123-deployment-receipts", scope, "production/operations/42.json"))
					require.Contains(t, receipt["checks"], execution["name"])
				} else {
					require.NotZero(t, code, out.String())
					require.FileExists(t, guard)
					if strings.HasPrefix(fault, "rotation-") || fault == "changed-promotion" || fault == "missing-prior" ||
						(service == "authentication" && (strings.HasPrefix(fault, "job-") || strings.HasPrefix(fault, "execution-"))) {
						require.Empty(t, events, "preconditions must prevent apply")
						require.FileExists(t, remotePlan)
					} else {
						require.NoFileExists(t, remotePlan, "uncertain execution must not leave a replayable plan")
					}
				}
			})
		}
	}
}
