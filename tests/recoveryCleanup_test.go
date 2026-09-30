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
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"google.golang.org/api/option"

	"github.com/a-novel/infra/internal/custody"
	infraworkflow "github.com/a-novel/infra/internal/workflow"
)

type cleanupProject struct {
	project, fault, state string
	deletes               int
}

func TestRecoveryCleanupNative(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name, fault   string
		code, deletes int
		guard         bool
	}{
		{"Success", "", 0, 1, false},
		{"Disabled", "disabled", 77, 0, false},
		{"WrongNumber", "number", 70, 0, true},
		{"UnrevokedAccess", "revoked", 77, 0, false},
		{"WrongRestoreGeneration", "generation", 70, 0, false},
		{"MissingPrivateEvidence", "evidence", 70, 0, false},
		{"MissingCompletion", "incomplete", 70, 0, false},
		{"ActiveWriter", "writer", 70, 0, false},
		{"CompetingSource", "busy", 70, 0, true},
		{"ChangedState", "state", 70, 0, true},
		{"RunningHost", "running", 70, 0, true},
		{"ReplacedDisk", "disk", 70, 0, true},
		{"RepeatedCleanup", "used", 70, 0, true},
		{"LostAdmission", "guard-ack", 70, 0, true},
		{"LostReservation", "attempt-ack", 70, 0, true},
		{"LostDeleteAcknowledgment", "delete-ack", 70, 1, true},
		{"MissingCompletionPublication", "completion-denied", 70, 1, true},
		{"LostCompletionAcknowledgment", "completion-ack", 70, 1, true},
		{"LostGuardDeletion", "unlock", 70, 1, true},
		{"ReconcileActiveProject", "reconcile-active", 70, 1, true},
		{"ReconcileActiveWriter", "reconcile-writer", 70, 1, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			f := setup(t)
			config := nativeInputs(t, f)
			input, err := json.Marshal(config)
			require.NoError(t, err)
			getenv := func(key string) string { return f.env[key] }
			host, err := infraworkflow.RecoveryScope(input, getenv, f.env["STATE_BUCKET"])
			require.NoError(t, err)
			runtime := newRecoveryHost(t, host.Request())
			project := &cleanupProject{project: host.Project, fault: tc.fault, state: "ACTIVE"}
			if strings.HasPrefix(tc.fault, "reconcile-") {
				project.fault = "delete-ack"
			}
			bucket := f.env["STATE_BUCKET"]
			receipts := strings.TrimSuffix(bucket, "-tofu-state") + "-deployment-receipts"
			guardName := "services/" + host.SourceProject + "/release/operation.json"
			prefix := "foundation/recovery/services/" + host.Project + "/"
			completionName := "services/" + host.SourceProject + "/production/operations/"
			objects, live := map[string][]byte{}, map[string]string{}
			put := func(bucket, name, generation string, value any) object {
				data, err := json.Marshal(value)
				require.NoError(t, err)
				key := bucket + "/" + name
				objects[key+"#"+generation], live[key] = data, generation
				return object{"bucket": bucket, "object": name, "generation": generation, "sha256": fmt.Sprintf("%x", sha256.Sum256(data))}
			}
			apply := object{"schemaVersion": 1, "root": "service-recovery", "project_id": host.Project, "source_project": host.SourceProject, "service": "json-keys", "region": host.Region, "commit": strings.Repeat("a", 40), "runId": "124", "runAttempt": "1", "planId": "123-1", "planSha256": strings.Repeat("b", 64), "inputsSha256": fmt.Sprintf("%x", sha256.Sum256(input))}
			prepared := put(receipts, completionName+"42.json", "44", object{
				"schemaVersion": 1, "outcome": "host-prepared", "operation": apply, "guard": put(bucket, guardName, "42", apply),
				"configuration": put(bucket, prefix+"config/00000000000000000124-00001.tfvars.json", "44", config),
				"state":         put(bucket, prefix+"default.tfstate", "44", object{"outputs": object{"recovery": object{"value": object{"selected": runtime.host.Target}}}}),
			})
			restore := object{"schemaVersion": 1, "kind": "native-restore", "target": runtime.host.Target, "preparation": prepared, "commit": strings.Repeat("a", 40), "runId": "125", "runAttempt": "1"}
			files := map[string]string{}
			for command, value := range runtime.replies {
				if name, ok := strings.CutPrefix(command, "sudo -n cat /mnt/disks/agora-recovery/work/attempt/"); ok {
					files[name] = value
				}
			}
			put(receipts, completionName+"43.json", "44", object{
				"outcome": host.Request().Outcome(), "operation": restore, "guard": put(bucket, guardName, "43", restore),
				"attempt":  put(bucket, prefix+"restore-attempt.json", "44", restore),
				"evidence": put(bucket, prefix+host.Request().Outcome()+".json", "44", files),
			})
			delete(live, bucket+"/"+guardName)
			f.env["NATIVE_RECOVERY_CLEANUP_ENABLED"], f.env["RECOVERY_OPERATION"] = "true", "cleanup-native"
			f.env["GITHUB_REPOSITORY"], f.env["GITHUB_SHA"] = "a-novel/infra", strings.Repeat("a", 40)
			f.env["GITHUB_RUN_ID"], f.env["GITHUB_RUN_ATTEMPT"] = "126", "1"
			authorization := object{"schemaVersion": 1, "replacementProject": host.Project, "projectNumber": "789", "service": "json-keys", "sourceProject": host.SourceProject, "restoreGeneration": "43", "crossProjectAccessRevoked": true}
			switch tc.fault {
			case "disabled":
				f.env["NATIVE_RECOVERY_CLEANUP_ENABLED"] = "false"
			case "revoked":
				authorization["crossProjectAccessRevoked"] = false
			case "generation":
				authorization["restoreGeneration"] = "99"
			case "evidence":
				delete(objects, bucket+"/"+prefix+host.Request().Outcome()+".json#44")
			case "incomplete":
				delete(live, receipts+"/"+completionName+"43.json")
			case "busy":
				put(bucket, guardName, "99", object{})
			case "running":
				runtime.vm["status"] = "RUNNING"
			case "disk":
				runtime.disk["id"] = "9999"
			case "used":
				put(bucket, prefix+"cleanup-attempt.json", "99", object{})
			}
			file, approval := filepath.Join(f.dir, "inputs.json"), filepath.Join(f.dir, "cleanup.json")
			writeJSON(t, file, config)
			writeJSON(t, approval, authorization)
			reconciling := false
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if strings.HasPrefix(r.URL.Path, "/v3/") {
					project.serve(t, w, r)
					return
				}
				w.Header().Set("Content-Type", "application/json")
				bucket, name, _ := strings.Cut(strings.TrimPrefix(r.URL.Path, "/b/"), "/o/")
				key := bucket + "/" + name
				switch r.Method {
				case http.MethodGet:
					generation := live[key]
					if selected := r.URL.Query().Get("generation"); selected != "" {
						generation = selected
					}
					data := objects[key+"#"+generation]
					if data == nil {
						http.Error(w, privateValue, http.StatusNotFound)
						return
					}
					if r.URL.Query().Get("alt") == "media" {
						_, _ = w.Write(data)
						return
					}
					if tc.fault == "state" && name == prefix+"default.tfstate" && live[bucket+"/"+guardName] == "100" {
						generation = "45"
					}
					assert.NoError(t, json.NewEncoder(w).Encode(object{"bucket": bucket, "name": name, "generation": generation}))
				case http.MethodPost:
					assert.Equal(t, "0", r.URL.Query().Get("ifGenerationMatch"))
					name, data := rotationUpload(t, r)
					bucket = strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/upload/storage/v1/b/"), "/o")
					key = bucket + "/" + name
					stage := "attempt"
					if name == guardName {
						stage = "guard"
					}
					if strings.HasSuffix(name, "/100.json") {
						stage = "completion"
					}
					if live[key] != "" || (tc.fault == stage+"-denied" && !reconciling) {
						http.Error(w, privateValue, http.StatusPreconditionFailed)
						return
					}
					objects[key+"#100"], live[key] = data, "100"
					if tc.fault == stage+"-ack" && !reconciling {
						http.Error(w, privateValue, http.StatusForbidden)
						return
					}
					assert.NoError(t, json.NewEncoder(w).Encode(object{"bucket": bucket, "name": name, "generation": "100"}))
				case http.MethodDelete:
					assert.Equal(t, []string{guardName, "100", ""}, []string{name, r.URL.Query().Get("ifGenerationMatch"), r.URL.Query().Get("generation")})
					if tc.fault == "unlock" && !reconciling {
						http.Error(w, privateValue, http.StatusForbidden)
						return
					}
					delete(live, key)
					w.WriteHeader(http.StatusNoContent)
				default:
					t.Errorf("unexpected custody method %s", r.Method)
				}
			}))
			t.Cleanup(server.Close)
			execute := func(ctx context.Context, out io.Writer, command string, args ...string) error {
				switch command {
				case "./ops/verify-deletion-label.sh":
					return nil
				case "gh":
					run, operation, status := 125, "restore-native", "completed"
					if reconciling {
						run, operation = 126, "cleanup-native"
					}
					if tc.fault == "writer" || (reconciling && tc.fault == "reconcile-writer") {
						status = "in_progress"
					}
					return json.NewEncoder(out).Encode(object{"id": run, "run_attempt": 1, "status": status, "head_branch": "master", "head_sha": strings.Repeat("a", 40), "event": "workflow_dispatch", "path": ".github/workflows/recovery.yaml", "repository": "a-novel/infra", "display_title": "recovery " + operation + " " + host.Project + " by @operator"})
				default:
					require.Equal(t, "100", live[bucket+"/"+guardName])
					return runtime.execute(ctx, out, command, args...)
				}
			}
			var output bytes.Buffer
			run := func(args ...string) int {
				output.Reset()
				return custody.Run(t.Context(), args, getenv, execute, &output, &output, option.WithEndpoint(server.URL), option.WithoutAuthentication())
			}
			code := run("recovery", "cleanup", bucket, file, approval, "DELETE "+host.Project)
			expectCode(t, tc.code, code, output.String())
			require.Equal(t, tc.deletes, project.deletes)
			require.Equal(t, tc.guard, live[bucket+"/"+guardName] != "")
			for _, command := range runtime.commands {
				require.Contains(t, command, "describe", "cleanup must not start or modify the host")
			}
			if tc.deletes == 1 {
				reconciling = true
				expected := 0
				if strings.HasPrefix(tc.fault, "reconcile-") {
					expected = 70
				}
				if tc.fault == "reconcile-active" {
					project.state = "ACTIVE"
				}
				f.env["SERVICE_OPERATION_RECOVERY_ENABLED"] = "true"
				f.env["GITHUB_WORKFLOW_REF"] = "a-novel/infra/.github/workflows/foundation.yaml@refs/heads/master"
				code = run("operation", "finish", bucket, host.SourceProject, "100", "FINISH json-keys 100")
				expectCode(t, expected, code, output.String())
				require.Equal(t, 1, project.deletes, "reconciliation must not repeat deletion")
				require.Equal(t, expected != 0, live[bucket+"/"+guardName] != "")
				require.Equal(t, "44", live[bucket+"/"+prefix+"restore-attempt.json"])
			}
		})
	}
}

func (project *cleanupProject) serve(t *testing.T, w http.ResponseWriter, r *http.Request) {
	t.Helper()
	w.Header().Set("Content-Type", "application/json")
	var reply any
	switch r.Method {
	case http.MethodGet:
		assert.Contains(t, []string{"/v3/projects/789", "/v3/projects/" + project.project}, r.URL.Path)
		labels := object{"application": "agora", "environment": "production", "managed-by": "opentofu", "plane": "workload", "recovery": "true"}
		reply = object{"projectId": project.project, "name": "projects/789", "state": project.state, "labels": labels}
		switch project.fault {
		case "labels":
			labels["recovery"] = "false"
		case "number":
			reply.(object)["name"] = "projects/999"
		case "peer":
			reply.(object)["projectId"] = "a-novel-recovery-peer"
		}
	case http.MethodPost:
		assert.Equal(t, "/v3/projects/789:getIamPolicy", r.URL.Path)
		binding := object{"role": "roles/resourcemanager.projectDeleter", "members": []string{"serviceAccount:infra-recovery@agora-management-test.iam.gserviceaccount.com"}}
		if project.fault == "iam" {
			binding["members"] = []string{}
		}
		if project.fault == "condition" {
			binding["condition"] = object{"expression": "true"}
		}
		reply = object{"bindings": []object{binding}}
	case http.MethodDelete:
		assert.Equal(t, "/v3/projects/789", r.URL.Path)
		project.deletes++
		project.state = "DELETE_REQUESTED"
		if project.fault == "delete-ack" {
			http.Error(w, privateValue, http.StatusInternalServerError)
			return
		}
		reply = object{"name": "operations/delete-trial"}
	default:
		t.Errorf("unexpected project method %s", r.Method)
	}
	assert.NoError(t, json.NewEncoder(w).Encode(reply))
}

func TestRecoveryCleanupLegacy(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name, fault   string
		code, deletes int
	}{
		{"Success", "", 0, 1},
		{"WrongConfirmation", "confirmation", 65, 0},
		{"RevocationNotAttested", "revoked", 77, 0},
		{"WrongReceipt", "receipt", 77, 0},
		{"UnknownApprovalField", "unknown", 77, 0},
		{"ProtectedManagement", "management", 77, 0},
		{"ProtectedWorkload", "workload", 77, 0},
		{"ProtectedService", "service", 77, 0},
		{"MissingMergedLabel", "approval", 77, 0},
		{"NotDisposable", "labels", 77, 0},
		{"PeerIdentity", "peer", 70, 0},
		{"NotActive", "state", 70, 0},
		{"NoDeleter", "iam", 77, 0},
		{"ConditionalDeleter", "condition", 77, 0},
		{"LostDeleteAcknowledgment", "delete-ack", 70, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			f := setup(t)
			nativeInputs(t, f)
			project := &cleanupProject{project: "a-novel-recovery-proof", fault: tc.fault, state: "ACTIVE"}
			f.env["GITHUB_REPOSITORY"], f.env["GITHUB_SHA"] = "a-novel/infra", strings.Repeat("a", 40)
			authorization := object{"schemaVersion": 1, "replacementProject": project.project, "sourceReceipt": "500-1", "crossProjectAccessRevoked": true}
			confirm := "DELETE " + project.project
			switch tc.fault {
			case "confirmation":
				confirm = "DELETE peer"
			case "revoked":
				authorization["crossProjectAccessRevoked"] = false
			case "receipt":
				authorization["sourceReceipt"] = "501-1"
			case "unknown":
				authorization["extra"] = true
			case "state":
				project.state = "DELETE_REQUESTED"
			case "management", "workload":
				f.env["FOUNDATION_CONFIG"] = strings.ReplaceAll(f.env["FOUNDATION_CONFIG"], "agora-"+map[string]string{"management": "management", "workload": "production"}[tc.fault]+"-test", project.project)
			case "service":
				f.env["FOUNDATION_CONFIG"] = strings.ReplaceAll(f.env["FOUNDATION_CONFIG"], "agora-authentication-test", project.project)
			}
			file := filepath.Join(f.dir, "authorization.json")
			writeJSON(t, file, authorization)
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { project.serve(t, w, r) }))
			t.Cleanup(server.Close)
			execute := func(_ context.Context, _ io.Writer, command string, args ...string) error {
				require.Equal(t, []string{"./ops/verify-deletion-label.sh", "a-novel/infra", strings.Repeat("a", 40)}, append([]string{command}, args...))
				if tc.fault == "approval" {
					return errors.New(privateValue)
				}
				return nil
			}
			var out bytes.Buffer
			code := custody.Run(t.Context(), []string{"recovery", "cleanup-project", f.env["STATE_BUCKET"], project.project, "500-1", file, confirm}, func(k string) string { return f.env[k] }, execute, &out, &out, option.WithEndpoint(server.URL), option.WithoutAuthentication())
			expectCode(t, tc.code, code, out.String())
			require.Equal(t, tc.deletes, project.deletes)
		})
	}
}
