package tests_test

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"mime"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"google.golang.org/api/option"
	"google.golang.org/api/storage/v1"

	"github.com/a-novel/infra/internal/custody"
	infraworkflow "github.com/a-novel/infra/internal/workflow"
)

func TestNativeRecoveryExecution(t *testing.T) {
	t.Parallel()
	for _, layout := range []string{"Dedicated", "Shared", "SharedAuthentication"} {
		for _, tc := range []struct {
			name, fault string
			code        int
			guard, host bool
		}{
			{"Success", "", 0, false, true},
			{"Disabled", "disabled", 77, false, false},
			{"WrongConfirmation", "confirmation", 65, false, false},
			{"LegacyPreparation", "missing-state", 65, false, false},
			{"ChangedInputs", "inputs", 65, false, false},
			{"WrongPreparationSchema", "schema", 70, false, false},
			{"WrongPreparationScope", "scope", 70, false, false},
			{"CompetingSource", "busy", 70, true, false},
			{"ChangedState", "state", 70, true, false},
			{"UsedDestination", "used", 70, true, false},
			{"LostAdmission", "guard-ack", 70, true, false},
			{"LostReservation", "attempt-ack", 70, true, false},
			{"UncertainWorker", "systemctl start", 70, true, true},
			{"LostCompletion", "completion-ack", 70, true, true},
			{"LostGuardDeletion", "delete-ack", 70, true, true},
			{"SQLSuccess", "sql-success", 0, false, true},
			{"SQLDisabled", "sql-disabled", 77, false, false},
			{"SQLIncomplete", "sql-incomplete", 70, true, true},
			{"SQLWorkerFailure", "sql-agora-native-verify.service", 70, true, true},
			{"SQLNetworkBoundary", "sql-verify-network", 70, true, true},
			{"SQLLostCompletion", "sql-completion-ack", 70, true, true},
			{"SQLDataSuccess", "sql-data-success", 0, false, true},
			{"SQLDataMissing", "sql-data-missing", 70, true, true},
			{"SQLDataMismatch", "sql-data-mismatch", 70, true, true},
		} {
			t.Run(layout+"/"+tc.name, func(t *testing.T) {
				t.Parallel()
				f := setup(t)
				config := nativeInputs(t, f)
				if strings.HasPrefix(layout, "Shared") {
					service := "json-keys"
					if layout == "SharedAuthentication" {
						service = "authentication"
					}
					sharedNativeInputs(t, f, config, service)
				}
				verifySQL := strings.HasPrefix(tc.fault, "sql-")
				if verifySQL {
					nested(config, "recovery")["verify_sql"] = true
				}
				if strings.HasPrefix(tc.fault, "sql-data-") {
					nested(config, "recovery")["expected_data_sha256"] = strings.Repeat("a", 64)
				}
				file := filepath.Join(f.dir, "inputs.json")
				writeJSON(t, file, config)
				getenv := func(key string) string { return f.env[key] }
				input, err := os.ReadFile(file)
				require.NoError(t, err)
				host, err := infraworkflow.RecoveryScope(input, getenv, f.env["STATE_BUCKET"])
				require.NoError(t, err)
				service := host.Request().Service
				runtime := newRecoveryHost(t, host.Request())
				if verifySQL {
					runtime.fail = strings.TrimPrefix(tc.fault, "sql-")
				}
				if verifySQL && tc.fault != "sql-incomplete" {
					observed := host.ExpectedDataSHA256
					switch tc.fault {
					case "sql-data-missing":
						observed = ""
					case "sql-data-mismatch":
						observed = strings.Repeat("b", 64)
					}
					runtime.replies["sudo -n cat /mnt/disks/agora-recovery/work/attempt/verification/sql-verified.json"] = fmt.Sprintf(`{"system_id":%q,"set":%q,"postgresql_stopped":true,"data_sha256":%q}`, host.SystemID, host.Set, observed)
				}
				bucket, receipts := f.env["STATE_BUCKET"], strings.TrimSuffix(f.env["STATE_BUCKET"], "-tofu-state")+"-deployment-receipts"
				guardName := "services/" + host.SourceProject + "/release/operation.json"
				receiptScope, operationScope := "services/"+host.SourceProject, host.SourceProject
				if strings.HasPrefix(layout, "Shared") {
					guardName, receiptScope, operationScope = "foundation/operations/production/"+service+"/operation.json", "workloads/production/private/agora-private-test/"+service, "workloads/production/"+service
				}
				prefix := "foundation/recovery/services/" + host.Project + "/"
				objects := map[string][]byte{}
				put := func(bucket, name string, data []byte, generation string) object {
					objects[bucket+"/"+name] = data
					return object{"bucket": bucket, "object": name, "generation": generation, "sha256": fmt.Sprintf("%x", sha256.Sum256(data))}
				}
				encode := func(value any) []byte { data, err := json.Marshal(value); require.NoError(t, err); return data }
				intent := object{"schemaVersion": 1, "root": "service-recovery", "project_id": host.Project, "source_project": host.SourceProject, "service": service, "region": host.Region, "commit": strings.Repeat("a", 40), "runId": "124", "runAttempt": "1", "planId": "123-1", "planSha256": strings.Repeat("b", 64), "inputsSha256": fmt.Sprintf("%x", sha256.Sum256(input))}
				if strings.HasPrefix(layout, "Shared") {
					intent["schemaVersion"], intent["scope"] = 2, receiptScope
				}
				if tc.fault == "schema" {
					intent["schemaVersion"] = 3
				}
				if tc.fault == "scope" {
					intent["scope"] = "workloads/production/public-api/agora-public-api-test/json-keys"
				}
				guard := put(bucket, guardName, encode(intent), "42")
				archivedGuard := objects[bucket+"/"+guardName]
				var restoredGuard []byte
				delete(objects, bucket+"/"+guardName)
				prepared := object{
					"schemaVersion": 1, "outcome": "host-prepared", "operation": intent, "guard": guard,
					"configuration": put(bucket, prefix+"config/00000000000000000124-00001.tfvars.json", input, "44"),
					"state":         put(bucket, prefix+"default.tfstate", encode(object{"outputs": object{"recovery": object{"value": object{"selected": runtime.host.Target}}}}), "44"),
				}
				if tc.fault == "missing-state" {
					delete(prepared, "state")
				}
				put(receipts, receiptScope+"/production/operations/42.json", encode(prepared), "44")
				if tc.fault == "inputs" {
					nested(config, "recovery")["disk_gib"] = 20
					writeJSON(t, file, config)
				}
				if tc.fault == "busy" {
					objects[bucket+"/"+guardName] = []byte(`{}`)
				}
				if tc.fault == "used" {
					objects[bucket+"/"+prefix+"restore-attempt.json"] = []byte(`{}`)
				}
				f.env["NATIVE_RECOVERY_EXECUTION_ENABLED"], f.env["RECOVERY_OPERATION"] = "true", "restore-native"
				f.env["GITHUB_REPOSITORY"], f.env["GITHUB_SHA"] = "a-novel/infra", strings.Repeat("a", 40)
				f.env["GITHUB_RUN_ID"], f.env["GITHUB_RUN_ATTEMPT"] = "125", "1"
				confirmation := host.Request().Confirmation("42")
				f.env["NATIVE_RECOVERY_SQL_ENABLED"] = "true"
				if tc.fault == "sql-disabled" {
					f.env["NATIVE_RECOVERY_SQL_ENABLED"] = "false"
				}
				if tc.fault == "disabled" {
					f.env["NATIVE_RECOVERY_EXECUTION_ENABLED"] = "false"
				}
				if tc.fault == "confirmation" {
					confirmation = "RESTORE-FILES wrong 42"
				}
				if tc.fault == "systemctl start" {
					runtime.fail = tc.fault
				}
				server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					w.Header().Set("Content-Type", "application/json")
					bucket, name, _ := strings.Cut(strings.TrimPrefix(r.URL.Path, "/b/"), "/o/")
					key := bucket + "/" + name
					switch r.Method {
					case http.MethodGet:
						data, generation := objects[key], "44"
						if strings.HasSuffix(name, "restore-attempt.json") || strings.HasSuffix(name, host.Request().Outcome()+".json") || strings.HasSuffix(name, "/operations/100.json") {
							generation = "100"
						}
						if name == guardName {
							generation = "100"
							if r.URL.Query().Get("generation") == "42" {
								data, generation = archivedGuard, "42"
							}
							if r.URL.Query().Get("generation") == "100" {
								data = restoredGuard
							}
						}
						if data == nil {
							http.Error(w, privateValue, http.StatusNotFound)
							return
						}
						if r.URL.Query().Get("alt") == "media" {
							assert.Equal(t, generation, r.URL.Query().Get("generation"))
							_, err := w.Write(data)
							assert.NoError(t, err)
							return
						}
						if tc.fault == "state" && name == prefix+"default.tfstate" && objects[f.env["STATE_BUCKET"]+"/"+guardName] != nil {
							generation = "45"
						}
						assert.NoError(t, json.NewEncoder(w).Encode(object{"bucket": bucket, "name": name, "generation": generation}))
					case http.MethodPost:
						assert.Equal(t, "0", r.URL.Query().Get("ifGenerationMatch"))
						_, params, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
						if !assert.NoError(t, err) {
							return
						}
						reader := multipart.NewReader(r.Body, params["boundary"])
						part, err := reader.NextPart()
						if !assert.NoError(t, err) {
							return
						}
						var metadata storage.Object
						if !assert.NoError(t, json.NewDecoder(part).Decode(&metadata)) {
							return
						}
						part, err = reader.NextPart()
						if !assert.NoError(t, err) {
							return
						}
						data, err := io.ReadAll(part)
						if !assert.NoError(t, err) {
							return
						}
						bucket = strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/upload/storage/v1/b/"), "/o")
						key = bucket + "/" + metadata.Name
						if objects[key] != nil {
							http.Error(w, privateValue, http.StatusPreconditionFailed)
							return
						}
						objects[key] = data
						fault := ""
						if metadata.Name == guardName {
							fault = "guard-ack"
							restoredGuard = data
						}
						if strings.HasSuffix(metadata.Name, "restore-attempt.json") {
							fault = "attempt-ack"
						}
						if metadata.Name != guardName && strings.Contains(metadata.Name, "/operations/") {
							fault = "completion-ack"
						}
						if strings.TrimPrefix(tc.fault, "sql-") == fault && fault != "" {
							http.Error(w, privateValue, http.StatusForbidden)
							return
						}
						metadata.Bucket, metadata.Generation = bucket, 100
						assert.NoError(t, json.NewEncoder(w).Encode(&metadata))
					case http.MethodDelete:
						assert.Equal(t, []string{guardName, "100", ""}, []string{name, r.URL.Query().Get("ifGenerationMatch"), r.URL.Query().Get("generation")})
						if tc.fault == "delete-ack" && f.env["SERVICE_OPERATION_RECOVERY_ENABLED"] != "true" {
							http.Error(w, privateValue, http.StatusForbidden)
							return
						}
						delete(objects, key)
						w.WriteHeader(http.StatusNoContent)
					default:
						t.Errorf("unexpected storage method %s", r.Method)
					}
				}))
				t.Cleanup(server.Close)
				execute := func(ctx context.Context, out io.Writer, command string, args ...string) error {
					if command == "gh" {
						run, operation := 124, "apply-native"
						if strings.Contains(strings.Join(args, " "), "/runs/125/") {
							run, operation = 125, "restore-native"
						}
						return json.NewEncoder(out).Encode(object{"id": run, "run_attempt": 1, "status": "completed", "head_branch": "master", "head_sha": strings.Repeat("a", 40), "event": "workflow_dispatch", "path": ".github/workflows/recovery.yaml", "repository": "a-novel/infra", "display_title": "recovery " + operation + " " + host.Project + " by @operator"})
					}
					require.NotEmpty(t, objects[bucket+"/"+guardName], "host work requires source admission")
					require.NotEmpty(t, objects[bucket+"/"+prefix+"restore-attempt.json"], "host work requires destination reservation")
					return runtime.execute(ctx, out, command, args...)
				}
				var stdout, stderr bytes.Buffer
				code := custody.Run(t.Context(), []string{"recovery", "execute", bucket, file, "42", confirmation}, getenv, execute, &stdout, &stderr, option.WithEndpoint(server.URL), option.WithoutAuthentication())
				expectCode(t, tc.code, code, stdout.String()+stderr.String())
				require.Equal(t, []bool{tc.guard, tc.host}, []bool{objects[bucket+"/"+guardName] != nil, len(runtime.commands) > 0})
				if code == 0 {
					var completion object
					require.NoError(t, json.Unmarshal(objects[receipts+"/"+receiptScope+"/production/operations/100.json"], &completion))
					require.Equal(t, []any{host.Request().Outcome(), "TERMINATED"}, []any{completion["outcome"], runtime.vm["status"]})
				}
				if code == 0 || strings.HasSuffix(tc.fault, "completion-ack") || tc.fault == "delete-ack" {
					calls := len(runtime.commands)
					stdout.Reset()
					stderr.Reset()
					code = custody.Run(t.Context(), []string{"operation", "inspect", bucket, operationScope, "100"}, getenv, execute, &stdout, &stderr, option.WithEndpoint(server.URL), option.WithoutAuthentication())
					expectCode(t, 0, code, stdout.String()+stderr.String())
					outcome := "PostgreSQL not started or verified"
					if verifySQL {
						outcome = "SQL verified offline at backup consistency"
					}
					require.Contains(t, stdout.String(), outcome)
					f.env["SERVICE_OPERATION_RECOVERY_ENABLED"] = "true"
					f.env["GITHUB_WORKFLOW_REF"] = "a-novel/infra/.github/workflows/foundation.yaml@refs/heads/master"
					code = custody.Run(t.Context(), []string{"operation", "finish", bucket, operationScope, "100", "FINISH " + service + " 100"}, getenv, execute, &stdout, &stderr, option.WithEndpoint(server.URL), option.WithoutAuthentication())
					expectCode(t, 0, code, stdout.String()+stderr.String())
					require.Len(t, runtime.commands, calls, "inspection and finish must never replay host work")
				}
			})
		}
	}
}
