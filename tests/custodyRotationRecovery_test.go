package tests_test

import (
	"encoding/json"
	"io"
	"mime"
	"mime/multipart"
	"net/http"
	"strings"
	"sync"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestCustodyRotationRecovery(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, record, field, fault string
		value                      any
		code, writes, deletes      int
	}{
		{name: "Success", writes: 1, deletes: 1},
		{name: "Success/RetriedTask", record: "result", field: "retriedCount", value: 1, writes: 1, deletes: 1},
		{name: "Success/NoInitialExecution", record: "dispatch", field: "execution", value: nil, writes: 1, deletes: 1},
		{name: "Error/AbsentGuard", fault: "absent", code: 70},
		{name: "Error/ReservationMissing", fault: "reservation-missing", code: 70},
		{name: "Error/AcknowledgementMissing", fault: "dispatch-missing", code: 70},
		{name: "Error/DispatcherActive", record: "writer", field: "state", value: "ACTIVE", code: 70},
		{name: "Error/ReservationGuard", record: "reservation", field: "guardGeneration", value: "41", code: 70},
		{name: "Error/DispatchGuard", record: "dispatch", field: "guardGeneration", value: "41", code: 70},
		{name: "Error/RecreatedJob", record: "job", field: "uid", value: "bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee", code: 70},
		{name: "Error/ChangedJob", record: "job", field: "generation", value: "8", code: 70},
		{name: "Error/ChangedImage", record: "reservation", field: "image", value: privateValue, code: 70},
		{name: "Error/PeerOperation", record: "dispatch", field: "operation", value: "projects/999999/locations/europe-west1/operations/abcdef", code: 70},
		{name: "Error/OperationUnavailable", fault: "operation-denied", code: 70},
		{name: "Error/OperationPending", record: "native", field: "done", value: false, code: 70},
		{name: "Error/OperationFailed", record: "native", field: "error", value: object{"code": 13, "message": privateValue}, code: 70},
		{name: "Error/NoNativeResult", record: "native", field: "response", value: nil, code: 70},
		{name: "Error/WrongExecution", record: "dispatch", field: "executionUID", value: "bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee", code: 70},
		{name: "Error/ExecutionRunning", record: "result", field: "runningCount", value: 1, code: 70},
		{name: "Error/ExecutionFailed", record: "result", field: "failedCount", value: 1, code: 70},
		{name: "Error/NoCompletion", record: "result", field: "completionTime", value: nil, code: 70},
		{name: "Error/WrongTemplate", record: "result", field: "template", value: object{}, code: 70},
		{name: "Error/NoSuccessCondition", record: "result", field: "conditions", value: []any{}, code: 70},
		{name: "Error/SuccessorBeforePublication", fault: "successor", code: 70},
		{name: "Error/PublicationDenied", fault: "publish-denied", code: 70, writes: 1},
		{name: "Error/PublicationAcknowledgementLost", fault: "publish-ack", code: 70, writes: 1},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			fixture := newRotationInspection(t)
			fixture.finish()
			fixture.fault, fixture.deletes = "missing-completion", testCase.deletes
			if testCase.fault == "absent" {
				fixture.live = ""
			}
			records := rotationRecoveryRecords(t, fixture)
			if testCase.record != "" {
				records[testCase.record][testCase.field] = testCase.value
			}
			var mutex sync.Mutex
			var writes, guardReads int
			var ended bool
			var saved []byte
			fixture.handle = func(w http.ResponseWriter, r *http.Request) bool {
				mutex.Lock()
				defer mutex.Unlock()
				if r.URL.Path == "/v1/"+fixture.dispatcher {
					ended = true
					return false
				}
				if r.URL.Path == fixture.guard && r.Method == http.MethodGet && r.URL.Query().Get("alt") != "media" {
					guardReads++
					if testCase.fault == "successor" && guardReads == 3 {
						bucket, name, _ := strings.Cut(strings.TrimPrefix(fixture.guard, "/b/"), "/o/")
						_ = json.NewEncoder(w).Encode(object{"bucket": bucket, "name": name, "generation": "45"})
						return true
					}
				}
				if r.Method == http.MethodPost {
					writes++
					if !ended || guardReads < 3 || r.URL.Query().Get("ifGenerationMatch") != "0" {
						t.Error("publication requires stopped writer, exact live admission and create-only precondition")
					}
					name, data := rotationUpload(t, r)
					bucket, expected, _ := strings.Cut(strings.TrimPrefix(fixture.completion, "/b/"), "/o/")
					if name != expected || r.URL.Path != "/upload/storage/v1/b/"+bucket+"/o" {
						t.Error("publication outside the selected rotation success record")
					}
					if testCase.fault == "publish-denied" {
						http.Error(w, privateValue, http.StatusForbidden)
						return true
					}
					saved = data
					if testCase.fault == "publish-ack" {
						http.Error(w, privateValue, http.StatusInternalServerError)
						return true
					}
					_ = json.NewEncoder(w).Encode(object{"bucket": bucket, "name": name, "generation": "43"})
					return true
				}
				prefix := strings.TrimSuffix(fixture.completion, "success.json")
				for path, key := range map[string]string{prefix + "intent.json": "reservation", prefix + "operation.json": "dispatch"} {
					if r.URL.Path == path {
						if testCase.fault == key+"-missing" {
							w.WriteHeader(http.StatusNotFound)
							return true
						}
						data, _ := json.Marshal(records[key])
						rotationObject(t, w, r, data)
						return true
					}
				}
				if r.URL.Path == fixture.completion && saved != nil {
					rotationObject(t, w, r, saved)
					return true
				}
				for path, key := range map[string]string{
					"/v2/projects/agora-json-keys-test/locations/europe-west1/jobs/agora-json-keys-rotatekeys": "job",
					"/v2/projects/123456789012/locations/europe-west1/operations/abcdef":                       "native",
				} {
					if r.URL.Path == path {
						if r.Method != http.MethodGet || !ended {
							t.Error("recovery permits only exact native reads after dispatcher termination")
						}
						if key == "native" && testCase.fault == "operation-denied" {
							http.Error(w, privateValue, http.StatusForbidden)
							return true
						}
						_ = json.NewEncoder(w).Encode(records[key])
						return true
					}
				}
				return false
			}
			fixture.check(t, testCase.code, "No deployment work repeated")
			require.Equal(t, testCase.writes, writes)
			if saved != nil {
				// Both writers feed the existing reader; lost publication acknowledgement
				// can be resolved without reconstructing or submitting native work again.
				fixture.args[1], fixture.args, fixture.deletes = "inspect", fixture.args[:5], 0
				fixture.check(t, 0, "recorded successful rotation")
			}
		})
	}
}

func rotationRecoveryRecords(t *testing.T, fixture *operationInspection) map[string]object {
	t.Helper()
	completion := fixture.records["completion"]
	jobUID := "cccccccc-bbbb-cccc-dddd-eeeeeeeeeeee"
	jobName := strings.Split(completion["execution"].(string), "/executions/")[0]
	image := "europe-west1-docker.pkg.dev/agora-json-keys-test/agora-production/service-json-keys/jobs/rotatekeys@sha256:" + strings.Repeat("a", 64)
	template := object{"containers": []object{{"image": image}}, "serviceAccount": "agora-json-keys@agora-json-keys-test.iam.gserviceaccount.com", "timeout": "300s", "maxRetries": 1}
	result := object{
		"@type": "type.googleapis.com/google.cloud.run.v2.Execution", "name": completion["execution"], "uid": completion["executionUID"], "job": jobName,
		"taskCount": 1, "parallelism": 1, "succeededCount": 1, "completionTime": completion["completedAt"], "template": template,
		"conditions": []object{{"type": "Completed", "state": "CONDITION_SUCCEEDED"}},
	}
	return map[string]object{
		"writer": fixture.writer, "result": result,
		"reservation": {"operation": fixture.records["intent"], "guardGeneration": "42", "job": jobName, "jobUID": jobUID, "jobGeneration": "7", "jobEtag": "before-dispatch", "image": image},
		"dispatch":    {"guardGeneration": "42", "operation": completion["runOperation"], "execution": completion["execution"], "executionUID": completion["executionUID"]},
		"job": {
			"name": jobName, "uid": jobUID, "generation": "7", "observedGeneration": "7", "etag": "after-dispatch",
			"template": object{"template": template}, "terminalCondition": object{"state": "CONDITION_SUCCEEDED"},
		},
		"native": {"name": completion["runOperation"], "done": true, "response": result},
	}
}

func rotationObject(t *testing.T, w http.ResponseWriter, r *http.Request, data []byte) {
	t.Helper()
	if r.Method != http.MethodGet {
		t.Error("records are read-only")
	}
	if r.URL.Query().Get("alt") == "media" {
		if r.URL.Query().Get("generation") != "43" {
			t.Error("record download must be generation-pinned")
		}
		_, _ = w.Write(data)
		return
	}
	bucket, name, _ := strings.Cut(strings.TrimPrefix(r.URL.Path, "/b/"), "/o/")
	_ = json.NewEncoder(w).Encode(object{"bucket": bucket, "name": name, "generation": "43"})
}

func rotationUpload(t *testing.T, request *http.Request) (string, []byte) {
	t.Helper()
	_, params, err := mime.ParseMediaType(request.Header.Get("Content-Type"))
	if err != nil {
		panic(err)
	}
	reader := multipart.NewReader(request.Body, params["boundary"])
	metadata, err := reader.NextPart()
	if err != nil {
		panic(err)
	}
	var entry struct{ Name string }
	if err := json.NewDecoder(metadata).Decode(&entry); err != nil {
		panic(err)
	}
	media, err := reader.NextPart()
	if err != nil {
		panic(err)
	}
	data, err := io.ReadAll(media)
	if err != nil {
		panic(err)
	}
	return entry.Name, data
}
