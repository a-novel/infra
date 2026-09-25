package submission_test

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"cloud.google.com/go/deploy/apiv1/deploypb"
	"cloud.google.com/go/longrunning/autogen/longrunningpb"
	"cloud.google.com/go/run/apiv2/runpb"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"google.golang.org/api/option"
	"google.golang.org/api/storage/v1"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/anypb"

	"github.com/a-novel/infra/internal/custody"
	"github.com/a-novel/infra/internal/submission"
)

func TestOperation(t *testing.T) {
	t.Parallel()
	registry, digest := operationRegistry(t)
	type result struct {
		code, releases, migrations, rollouts int
		held, receipt                        bool
	}
	for _, testCase := range []struct {
		name   string
		want   result
		finish *result
	}{
		{"Success", result{0, 1, 1, 1, false, true}, nil},
		{"HumanApproved", result{0, 1, 1, 1, false, true}, nil},
		{"Busy", result{1, 0, 0, 0, true, false}, nil},
		{"GuardAckLost", result{1, 0, 0, 0, true, false}, nil},
		{"JobChanged", result{1, 0, 0, 0, true, false}, nil},
		{"DispatchTemplateChanged", result{1, 1, 0, 0, true, false}, nil},
		{"MigrationAckLost", result{1, 1, 1, 0, true, false}, nil},
		{"MigrationFailed", result{1, 1, 1, 0, true, false}, nil},
		{"AwaitApprovalInterrupted", result{1, 1, 1, 1, true, false}, nil},
		{"VerificationFailed", result{1, 1, 1, 1, true, false}, nil},
		{"ReceiptDenied", result{1, 1, 1, 1, true, false}, nil},
		{"ReceiptAckLost", result{1, 1, 1, 1, true, true}, nil},
		{"GuardReplaced", result{1, 1, 1, 1, true, true}, nil},
		{"FinishSuccess", result{1, 1, 1, 1, true, false}, &result{0, 1, 1, 1, false, true}},
		{"FinishActiveWriter", result{1, 1, 1, 1, true, false}, &result{70, 1, 1, 1, true, false}},
		{"FinishWrongAttempt", result{1, 1, 1, 1, true, false}, &result{70, 1, 1, 1, true, false}},
		{"FinishAbsentGuard", result{1, 1, 1, 1, true, false}, &result{70, 1, 1, 1, false, false}},
		{"FinishSuccessor", result{1, 1, 1, 1, true, false}, &result{70, 1, 1, 1, true, false}},
		{"FinishGuardChanged", result{1, 1, 1, 1, true, false}, &result{70, 1, 1, 1, true, false}},
		{"FinishReadDenied", result{1, 1, 1, 1, true, false}, &result{70, 1, 1, 1, true, false}},
		{"FinishVerificationFailed", result{1, 1, 1, 1, true, false}, &result{70, 1, 1, 1, true, false}},
		{"FinishTrafficChanged", result{1, 1, 1, 1, true, false}, &result{70, 1, 1, 1, true, false}},
		{"FinishWrongRelease", result{1, 1, 1, 1, true, false}, &result{70, 1, 1, 1, true, false}},
		{"FinishWrongRollout", result{1, 1, 1, 1, true, false}, &result{70, 1, 1, 1, true, false}},
		{"FinishJobChanged", result{1, 1, 1, 1, true, false}, &result{70, 1, 1, 1, true, false}},
		{"FinishMigrationUID", result{1, 1, 1, 1, true, false}, &result{70, 1, 1, 1, true, false}},
		{"FinishMigrationChanged", result{1, 1, 1, 1, true, false}, &result{70, 1, 1, 1, true, false}},
		{"FinishMissingMigration", result{1, 1, 1, 1, true, false}, &result{70, 1, 1, 1, true, false}},
		{"FinishReceiptConflict", result{1, 1, 1, 1, true, false}, &result{70, 1, 1, 1, true, false}},
		{"FinishAckLost", result{1, 1, 1, 1, true, false}, &result{70, 1, 1, 1, true, true}},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			directory := operationCheckout(t, digest)
			request := fixture(t)
			bindSource(t, request, directory)
			request.Release.BuildArtifacts[0].Tag = "europe-west1-docker.pkg.dev/agora-json-keys-test/agora-production/service-json-keys/grpc@" + digest
			released := proto.Clone(request.Release).(*deploypb.Release)
			released.Uid, released.RenderState = "release-uid", deploypb.Release_SUCCEEDED
			target := &deploypb.Target{
				Name: "projects/123456/locations/europe-west1/targets/agora-json-keys-grpc", Uid: "target-uid", RequireApproval: true,
				DeploymentTarget: &deploypb.Target_Run{Run: &deploypb.CloudRunLocation{Location: "projects/123456/locations/europe-west1"}},
			}
			released.TargetSnapshots = []*deploypb.Target{target}
			migration, execution := migrationFixture(t, released)
			migration.Template.Template.Containers[0].Image = "europe-west1-docker.pkg.dev/agora-json-keys-test/agora-production/service-json-keys/jobs/migrations@" + digest
			execution.Template = proto.Clone(migration.Template.Template).(*runpb.TaskTemplate)
			rotation := proto.Clone(migration).(*runpb.Job)
			rotation.Name = strings.Replace(migration.Name, "migrations", "rotatekeys", 1)
			rotation.Template.Template.Containers[0].Name = "rotatekeys"
			rotation.Template.Template.Containers[0].Image = strings.Replace(migration.Template.Template.Containers[0].Image, "migrations@", "rotatekeys@", 1)
			config, env := operationFixture(t, request, migration, rotation)
			config["foundation"] = map[string]string{"private": "<private>&configuration"}
			var formatted bytes.Buffer
			require.NoError(t, json.Indent(&formatted, encodeOperation(t, config), "", "  "))
			data := bytes.ReplaceAll(formatted.Bytes(), []byte(`\u0026`), []byte("&"))
			file := filepath.Join(t.TempDir(), "approved.json")
			require.NoError(t, os.WriteFile(file, data, 0o600))
			priorRequest := proto.Clone(request).(*deploypb.CreateReleaseRequest)
			priorRequest.ReleaseId = "previous"
			priorRequest.Release.Name = request.Parent + "/releases/previous"
			prior := proto.Clone(priorRequest.Release).(*deploypb.Release)
			prior.Uid, prior.RenderState = "previous-uid", deploypb.Release_SUCCEEDED
			previousRollout := operationRollout(t, prior)
			native := operationRollout(t, released)
			serviceName := "projects/123456/locations/europe-west1/services/agora-json-keys-grpc"
			service := &runpb.Service{
				Name: serviceName, Uid: "service-uid", Generation: 1, ObservedGeneration: 1,
				TerminalCondition: &runpb.Condition{State: runpb.Condition_CONDITION_SUCCEEDED}, Ingress: runpb.IngressTraffic_INGRESS_TRAFFIC_INTERNAL_ONLY,
			}
			stateBucket := env["STATE_BUCKET"]
			guard := "services/agora-json-keys-test/release/operation.json"
			objects := map[string][]byte{bucket + "/" + strings.Replace(intent, "release-1.json", "previous.json", 1): wire(t, priorRequest)}
			objects[bucket+"/"+strings.Replace(intent, "release-1.json", "previous.rollout.json", 1)] = wire(t, &deploypb.CreateRolloutRequest{
				Parent: prior.Name, RolloutId: "production", RequestId: previousRollout.Annotations["request-id"], StartingPhaseId: "canary-0",
				Rollout: &deploypb.Rollout{Name: previousRollout.Name, TargetId: previousRollout.TargetId, Annotations: previousRollout.Annotations},
			})
			if testCase.name == "Busy" {
				objects[stateBucket+"/"+guard] = []byte(`{"kind":"rotation"}`)
			}
			var mutex sync.Mutex
			var got result
			var storedGuard []byte
			repairing := false
			approvalReads := 0
			generation := int64(1)
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				mutex.Lock()
				defer mutex.Unlock()
				w.Header().Set("Content-Type", "application/json")
				write := func(message proto.Message) { _, _ = w.Write(wire(t, message)) }
				completed := func(name string, message proto.Message) {
					response, err := anypb.New(message)
					if err != nil {
						panic(err)
					}
					write(&longrunningpb.Operation{Name: name, Done: true, Result: &longrunningpb.Operation_Response{Response: response}})
				}
				switch {
				case r.Method == http.MethodPost && strings.HasPrefix(r.URL.Path, "/upload/storage/v1/b/"):
					object, body := upload(t, r)
					selectedBucket := strings.Split(r.URL.Path, "/")[5]
					key := selectedBucket + "/" + object.Name
					if r.URL.Query().Get("ifGenerationMatch") != "0" {
						t.Error("unguarded object write")
					}
					if _, exists := objects[key]; exists {
						w.WriteHeader(http.StatusPreconditionFailed)
						return
					}
					receipt := strings.Contains(object.Name, "/native-success/")
					if repairing && !receipt {
						t.Error("repair may only publish native completion")
						w.WriteHeader(http.StatusForbidden)
						return
					}
					if strings.Contains(object.Name, "/production/operations/") {
						t.Error("native completion must not write a duplicate pointer")
						w.WriteHeader(http.StatusForbidden)
						return
					}
					if receipt && (testCase.name == "ReceiptDenied" || (testCase.finish != nil && !repairing)) {
						w.WriteHeader(http.StatusForbidden)
						return
					}
					if receipt && repairing && testCase.name == "FinishReceiptConflict" {
						w.WriteHeader(http.StatusPreconditionFailed)
						return
					}
					objects[key] = body
					if object.Name == guard {
						storedGuard = body
					}
					got.receipt = got.receipt || receipt
					if (object.Name == guard && testCase.name == "GuardAckLost") || (receipt && (testCase.name == "ReceiptAckLost" || testCase.name == "FinishAckLost")) {
						w.WriteHeader(http.StatusServiceUnavailable)
						return
					}
					if receipt && testCase.name == "GuardReplaced" {
						generation = 2
					}
					object.Bucket, object.Generation = selectedBucket, 1
					_ = json.NewEncoder(w).Encode(object)
				case strings.HasPrefix(r.URL.Path, "/b/"):
					parts := strings.SplitN(strings.TrimPrefix(r.URL.Path, "/b/"), "/o/", 2)
					key := parts[0] + "/" + parts[1]
					body, exists := objects[key]
					if parts[1] == guard && r.URL.Query().Get("generation") == "1" {
						body, exists = storedGuard, true
					}
					if !exists {
						http.NotFound(w, r)
						return
					}
					if parts[1] == guard {
						if match := r.URL.Query().Get("ifGenerationMatch"); match != "" && match != fmt.Sprint(generation) {
							w.WriteHeader(http.StatusPreconditionFailed)
							return
						}
						if r.Method == http.MethodDelete {
							assert.Equal(t, "1", r.URL.Query().Get("ifGenerationMatch"))
							assert.Empty(t, r.URL.Query().Get("generation"))
							if !got.receipt {
								t.Error("unlock before durable completion")
							}
							delete(objects, key)
							w.WriteHeader(http.StatusNoContent)
							return
						}
						if r.URL.Query().Get("alt") == "media" {
							assert.Equal(t, "1", r.URL.Query().Get("generation"))
							_, _ = w.Write(body)
						} else {
							_ = json.NewEncoder(w).Encode(&storage.Object{Name: guard, Bucket: stateBucket, Generation: generation})
						}
						return
					}
					if r.URL.Query().Get("alt") == "media" {
						_, _ = w.Write(body)
					} else {
						_ = json.NewEncoder(w).Encode(&storage.Object{Name: parts[1], Bucket: parts[0], Generation: 1})
					}
				case r.Method == http.MethodGet:
					if repairing && (testCase.name == "FinishActiveWriter" || testCase.name == "FinishWrongAttempt" || testCase.name == "FinishAbsentGuard" || testCase.name == "FinishSuccessor") {
						t.Error("repair read native state before writer/guard authorization")
					}
					if repairing && testCase.name == "FinishReadDenied" {
						w.WriteHeader(http.StatusForbidden)
						return
					}
					switch r.URL.Path {
					case "/v1/" + prior.Name:
						write(prior)
					case "/v1/" + previousRollout.Name:
						write(previousRollout)
					case "/v1/" + released.Name:
						write(released)
					case "/v1/" + native.Name:
						if testCase.name == "HumanApproved" {
							if approvalReads > 0 {
								native.ApprovalState = deploypb.Rollout_APPROVED
							}
							approvalReads++
						}
						write(native)
					case "/v1/" + target.Name:
						write(target)
					case "/v2/" + serviceName:
						revision := previousRollout.Metadata.GetCloudRun().Revision
						if got.rollouts > 0 {
							revision = native.Metadata.GetCloudRun().Revision
						}
						service.TrafficStatuses = []*runpb.TrafficTargetStatus{{Revision: revision, Percent: 100}}
						if repairing && testCase.name == "FinishTrafficChanged" {
							service.TrafficStatuses[0].Revision = "unexpected-revision"
						}
						write(service)
					case "/v2/" + migration.Name:
						job := proto.Clone(migration).(*runpb.Job)
						if repairing && testCase.name == "FinishGuardChanged" {
							generation = 2
						}
						if testCase.name == "JobChanged" || (testCase.name == "DispatchTemplateChanged" && got.releases > 0) {
							job.Template.Template.Containers[0].Env = []*runpb.EnvVar{{Name: "UNAPPROVED"}}
						}
						write(job)
					case "/v2/" + rotation.Name:
						write(rotation)
					case "/v2/" + operationName:
						completed(operationName, execution)
					default:
						t.Errorf("unexpected read %s", r.URL.Path)
						w.WriteHeader(http.StatusForbidden)
					}
				case r.Method == http.MethodPost:
					if repairing {
						t.Error("repair must not dispatch native work")
						w.WriteHeader(http.StatusForbidden)
						return
					}
					if _, held := objects[stateBucket+"/"+guard]; !held {
						t.Error("dispatch without service admission")
					}
					switch r.URL.Path {
					case "/v1/" + request.Parent + "/releases":
						got.releases++
						completed(operationName, released)
					case "/v2/" + migration.Name + ":run":
						got.migrations++
						if testCase.name == "MigrationAckLost" {
							w.WriteHeader(http.StatusServiceUnavailable)
							return
						}
						if testCase.name == "MigrationFailed" {
							execution.FailedCount = 1
						}
						completed(operationName, execution)
					case "/v1/" + released.Name + "/rollouts":
						got.rollouts++
						if testCase.name == "AwaitApprovalInterrupted" || testCase.name == "HumanApproved" {
							native.ApprovalState = deploypb.Rollout_NEEDS_APPROVAL
						}
						if testCase.name == "VerificationFailed" {
							native.State = deploypb.Rollout_FAILED
							native.Phases[1].GetDeploymentJobs().VerifyJob.State = deploypb.Job_FAILED
						}
						completed(operationName, native)
					default:
						t.Errorf("unexpected mutation %s", r.URL.Path)
						w.WriteHeader(http.StatusForbidden)
					}
				default:
					t.Errorf("unexpected method %s", r.Method)
				}
			}))
			defer server.Close()
			execute := func(_ context.Context, output io.Writer, name string, _ ...string) error {
				if name == "gcloud" {
					_, err := io.WriteString(output, "ENABLED\n")
					return err
				}
				if name != "gh" {
					t.Errorf("unexpected child %s", name)
				}
				if repairing {
					status, attempt := "completed", 1
					if testCase.name == "FinishActiveWriter" {
						status = "in_progress"
					}
					if testCase.name == "FinishWrongAttempt" {
						attempt = 2
					}
					return json.NewEncoder(output).Encode(map[string]any{
						"id": env["GITHUB_RUN_ID"], "run_attempt": attempt, "status": status,
						"head_branch": "master", "head_sha": request.Release.Annotations["source-commit"],
						"event": "workflow_dispatch", "path": ".github/workflows/release.yaml",
						"repository": "a-novel/infra", "display_title": "production deploy-service by @operator",
					})
				}
				return nil
			}
			timeout := "30s"
			if testCase.name == "AwaitApprovalInterrupted" {
				timeout = "2s"
			}
			args := []string{"deploy", "--source-dir=" + directory, "--timeout=" + timeout, file, fmt.Sprintf("%x", sha256.Sum256(data))}
			var output bytes.Buffer
			options := []option.ClientOption{option.WithEndpoint(server.URL), option.WithoutAuthentication()}
			got.code = submission.Operation(t.Context(), args, func(key string) string { return env[key] }, execute, registry, &output, &output, options...)
			mutex.Lock()
			_, got.held = objects[stateBucket+"/"+guard]
			mutex.Unlock()
			require.Equal(t, testCase.want, got, "%s", &output)
			if storedGuard != nil {
				// Inspection remains usable after disabling the writer or changing master.
				readerEnv := func(key string) string {
					if strings.HasPrefix(key, "GITHUB_") || key == "SERVICE_NATIVE_RELEASE_ENABLED" {
						return ""
					}
					return env[key]
				}
				evidence, err := submission.InspectOperation(storedGuard, 1, stateBucket, "agora-json-keys-test", readerEnv, func(name string) ([]byte, error) {
					require.Equal(t, "services/agora-json-keys-test/production/native-success/release-1.json", name)
					return objects[bucket+"/"+name], nil
				})
				require.NoError(t, err)
				require.Equal(t, got.receipt, evidence.Completed)
			}
			if got.code != 0 {
				before := got.migrations
				require.Equal(t, 1, submission.Operation(t.Context(), args, func(key string) string { return env[key] }, execute, registry, &output, &output, options...))
				require.Equal(t, before, got.migrations, "a new invocation cannot replay a held operation")
			}
			if testCase.finish == nil {
				return
			}
			// Re-use the actual interrupted writer's records. The finisher cannot
			// submit native work; only completion publication and guard deletion remain.
			repairing = true
			switch testCase.name {
			case "FinishAbsentGuard":
				delete(objects, stateBucket+"/"+guard)
			case "FinishSuccessor":
				generation = 2
			case "FinishVerificationFailed":
				native.Phases[1].GetDeploymentJobs().VerifyJob.State = deploypb.Job_FAILED
			case "FinishJobChanged":
				rotation.Uid = "different-job-uid"
			case "FinishWrongRelease":
				released.SkaffoldVersion, request.Release.SkaffoldVersion = "2.99.0", "2.99.0"
				objects[bucket+"/"+intent] = wire(t, request)
			case "FinishWrongRollout":
				native.Annotations["request-id"] = "d149b2fa-41c3-438c-bd32-8a9d994c6a17"
				objects[bucket+"/"+strings.Replace(intent, ".json", ".rollout.json", 1)] = wire(t, &deploypb.CreateRolloutRequest{
					Parent: released.Name, RolloutId: "production", RequestId: native.Annotations["request-id"], StartingPhaseId: "canary-0",
					Rollout: &deploypb.Rollout{Name: native.Name, TargetId: native.TargetId, Annotations: native.Annotations},
				})
			case "FinishMissingMigration":
				delete(objects, bucket+"/"+strings.Replace(intent, ".json", ".migration.execution.json", 1))
			case "FinishMigrationUID", "FinishMigrationChanged":
				snapshot := proto.Clone(migration).(*runpb.Job)
				if testCase.name == "FinishMigrationUID" {
					snapshot.Uid = "a149b2fa-41c3-438c-bd32-8a9d994c6a17"
				} else {
					snapshot.Template.Template.Containers[0].Env = append(snapshot.Template.Template.Containers[0].Env, &runpb.EnvVar{Name: "UNAPPROVED"})
					execution.Template = proto.Clone(snapshot.Template.Template).(*runpb.TaskTemplate)
					objects[bucket+"/"+strings.Replace(intent, ".json", ".migration.execution.json", 1)] = wire(t, execution)
				}
				objects[bucket+"/"+strings.Replace(intent, ".json", ".migration.json", 1)] = encodeOperation(t, map[string]any{
					"schemaVersion": 1, "releaseUid": released.Uid, "job": json.RawMessage(wire(t, snapshot)),
				})
			}
			env["GITHUB_WORKFLOW_REF"] = "a-novel/infra/.github/workflows/foundation.yaml@refs/heads/master"
			env["SERVICE_OPERATION_RECOVERY_ENABLED"] = "true"
			finishArgs := []string{"operation", "finish", stateBucket, "agora-json-keys-test", "1", "FINISH json-keys 1"}
			finish := func() result {
				output.Reset()
				got.code = custody.Run(t.Context(), finishArgs, func(key string) string { return env[key] }, execute, &output, &output, options...)
				_, got.held = objects[stateBucket+"/"+guard]
				return got
			}
			require.Equal(t, *testCase.finish, finish(), "%s", &output)
			if testCase.name == "FinishAckLost" {
				require.Equal(t, result{0, 1, 1, 1, false, true}, finish(), "saved completion permits cleanup after lost acknowledgement: %s", &output)
			}
		})
	}
}
