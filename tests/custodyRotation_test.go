package tests_test

import (
	"strings"
	"testing"
)

func TestCustodyRotationInspection(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, fault, want string
		code              int
	}{
		{"Success", "", "recorded successful rotation", 0},
		{"Incomplete", "missing-completion", "rotation may still have run", 0},
		{"Denied", "denied-completion", "", 70},
		{"ChangedGuard", "changed-guard", "", 70},
		{"DuplicateField", "duplicate", "", 70},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			fixture := newRotationInspection(t)
			fixture.fault = testCase.fault
			fixture.check(t, testCase.code, testCase.want)
		})
	}
}

func TestCustodyRotationFinish(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, live, fault, field, value string
		code, deletes                   int
	}{
		{name: "Success/FailedAfterSuccess", live: "42", deletes: 1},
		{name: "Success/Succeeded", live: "42", field: "state", value: "SUCCEEDED", deletes: 1},
		{name: "Success/CancelledAfterSuccess", live: "42", field: "state", value: "CANCELLED", deletes: 1},
		{name: "Success/Absent"},
		{name: "Error/Successor", live: "45", code: 70},
		{name: "Error/MissingSuccess", live: "42", fault: "missing-completion", code: 70},
		{name: "Error/Active", live: "42", field: "state", value: "ACTIVE", code: 70},
		{name: "Error/Queued", live: "42", field: "state", value: "QUEUED", code: 70},
		{name: "Error/Unknown", live: "42", field: "state", value: "UNAVAILABLE", code: 70},
		{name: "Error/NoEnd", live: "42", field: "endTime", value: "", code: 70},
		{name: "Error/Revision", live: "42", field: "workflowRevisionId", value: "000002-def", code: 70},
		{name: "Error/Unavailable", live: "42", fault: "writer-unavailable", code: 70},
		{name: "Error/DeleteRace", live: "42", fault: "delete-race", code: 70, deletes: 1},
		{name: "Error/DeleteUnconfirmed", live: "42", fault: "delete-unconfirmed", code: 70, deletes: 1},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			fixture := newRotationInspection(t)
			fixture.finish()
			fixture.live, fixture.fault, fixture.deletes = testCase.live, testCase.fault, testCase.deletes
			if testCase.field != "" {
				fixture.writer[testCase.field] = testCase.value
			}
			fixture.check(t, testCase.code, "Private custody operation completed")
		})
	}
}

func TestCustodyRotationBinding(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name, record, field string
		value               any
	}{
		{"FutureSchema", "intent", "schemaVersion", 2},
		{"PeerProject", "intent", "project", "agora-peer-test"},
		{"PeerService", "intent", "service", "authentication"},
		{"PeerRegion", "intent", "region", "us-central1"},
		{"UnsafeWorkflow", "intent", "workflowExecution", privateValue},
		{"UnsafeRevision", "intent", "workflowRevision", privateValue + "\n"},
		{"WrongDispatcher", "operation", "workflowRevision", "000002-def"},
		{"WrongGeneration", "completion", "guardGeneration", "41"},
		{"InvalidTimestamp", "completion", "completedAt", privateValue},
		{"MissingTimestamp", "completion", "completedAt", nil},
		{"UnknownField", "completion", "unexpected", privateValue},
		{"PeerRun", "completion", "runOperation", "projects/agora-peer-test/locations/europe-west1/operations/123"},
		{"WrongJob", "completion", "execution", "projects/123456789012/locations/europe-west1/jobs/agora-json-keys-migrations/executions/agora-json-keys-migrations-abc"},
		{"MissingUID", "completion", "executionUID", ""},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			fixture := newRotationInspection(t)
			fixture.records[testCase.record][testCase.field] = testCase.value
			fixture.check(t, 70, "")
			fixture.finish()
			fixture.check(t, 70, "")
		})
	}
}

func newRotationInspection(t *testing.T) *operationInspection {
	t.Helper()
	fixture := newOperationInspection(t, "scheduled-rotation")
	id := "11111111-2222-3333-4444-555555555555"
	fixture.dispatcher = "projects/agora-json-keys-test/locations/europe-west1/workflows/agora-json-keys-rotation/executions/" + id
	intent := object{
		"schemaVersion": 1, "kind": "scheduled-rotation", "project": "agora-json-keys-test", "service": "json-keys", "region": "europe-west1",
		"workflowExecution": fixture.dispatcher, "workflowRevision": "000001-abc",
	}
	operation := object{}
	for key, value := range intent {
		operation[key] = value
	}
	fixture.records["intent"], fixture.records["operation"] = intent, operation
	fixture.records["completion"] = object{
		"operation": operation, "guardGeneration": "42", "runOperation": "projects/123456789012/locations/europe-west1/operations/abcdef",
		"execution":    "projects/123456789012/locations/europe-west1/jobs/agora-json-keys-rotatekeys/executions/agora-json-keys-rotatekeys-abc",
		"executionUID": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "completedAt": "2026-09-25T00:00:00Z",
	}
	fixture.completion = strings.Replace(fixture.completion, "operations/42.json", "rotations/"+id+"/success.json", 1)
	return fixture
}
