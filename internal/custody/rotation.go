package custody

import (
	"context"
	"regexp"
	"strings"
	"time"

	"google.golang.org/api/option"
	"google.golang.org/api/storage/v1"
	"google.golang.org/api/workflowexecutions/v1"
)

// rotationIntent identifies the native dispatcher that owns a service guard.
type rotationIntent struct {
	SchemaVersion     int    `json:"schemaVersion"`
	Kind              string `json:"kind"`
	Project           string `json:"project"`
	Service           string `json:"service"`
	Region            string `json:"region"`
	WorkflowExecution string `json:"workflowExecution"`
	WorkflowRevision  string `json:"workflowRevision"`
}

// rotationCompletion records native success, from the dispatcher or protected recovery.
type rotationCompletion struct {
	Operation       rotationIntent `json:"operation"`
	GuardGeneration int64          `json:"guardGeneration,string"`
	RunOperation    string         `json:"runOperation"`
	Execution       string         `json:"execution"`
	ExecutionUID    string         `json:"executionUID"`
	CompletedAt     time.Time      `json:"completedAt"`
}

var rotationID = regexp.MustCompile(`^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$`)

func inspectRotation(ctx context.Context, client *storage.Service, expected applyIntent, guard objectReference, data []byte) (*rotationIntent, bool, error) {
	intent := &rotationIntent{}
	if err := decodeRecord(data, intent); err != nil {
		return nil, false, err
	}
	if intent.SchemaVersion != 1 || intent.Kind != "scheduled-rotation" || intent.Service != "json-keys" {
		return nil, false, failure{70, "Unsupported rotation operation."}
	}
	if intent.Project != expected.Project || intent.Service != expected.Service || intent.Region != expected.Region {
		return nil, false, failure{70, "Rotation differs from the approved service scope."}
	}
	prefix := "projects/" + expected.Project + "/locations/" + expected.Region + "/workflows/agora-json-keys-rotation/executions/"
	executionID, scoped := strings.CutPrefix(intent.WorkflowExecution, prefix)
	if !scoped || !rotationID.MatchString(executionID) || !regexp.MustCompile(`^[a-zA-Z0-9-]{1,64}$`).MatchString(intent.WorkflowRevision) {
		return nil, false, failure{70, "Rotation dispatcher identity is invalid."}
	}
	receipts, prefix := intent.records(guard)
	name := prefix + "success.json"
	data, err := readCurrentObject(ctx, client, receipts, name)
	if err != nil || data == nil {
		return intent, false, err
	}
	var completion rotationCompletion
	if err := decodeRecord(data, &completion); err != nil {
		return nil, false, err
	}
	return intent, true, intent.checkCompletion(completion, guard)
}

func (intent rotationIntent) records(guard objectReference) (string, string) {
	_, id, _ := strings.Cut(intent.WorkflowExecution, "/executions/")
	return strings.TrimSuffix(guard.Bucket, "-tofu-state") + "-deployment-receipts",
		"services/" + intent.Project + "/production/rotations/" + id + "/"
}

// checkCompletion binds both dispatcher-written and repaired success to admission.
func (intent rotationIntent) checkCompletion(completion rotationCompletion, guard objectReference) error {
	if completion.Operation != intent || completion.GuardGeneration != guard.Generation || completion.CompletedAt.IsZero() {
		return failure{70, "Rotation completion does not match its exact guard and dispatcher."}
	}
	// Native Run names may use the project number. Both names must share that scope.
	location, operationID, found := strings.Cut(completion.RunOperation, "/operations/")
	locationPattern := `^projects/(` + regexp.QuoteMeta(intent.Project) + `|[1-9][0-9]*)/locations/` + regexp.QuoteMeta(intent.Region) + `$`
	executionPattern := `^` + regexp.QuoteMeta(location) + `/jobs/agora-json-keys-rotatekeys/executions/agora-json-keys-rotatekeys-[a-z0-9-]+$`
	if !found || !regexp.MustCompile(locationPattern).MatchString(location) || !regexp.MustCompile(`^[a-zA-Z0-9-]{1,128}$`).MatchString(operationID) {
		return failure{70, "Rotation completion has an invalid native operation."}
	}
	if !regexp.MustCompile(executionPattern).MatchString(completion.Execution) || !rotationID.MatchString(completion.ExecutionUID) {
		return failure{70, "Rotation completion has an invalid native execution."}
	}
	return nil
}

// completedWriter verifies termination; recorded success separately proves the job outcome.
func (intent rotationIntent) completedWriter(ctx context.Context, options []option.ClientOption) error {
	client, err := workflowexecutions.NewService(ctx, options...)
	if err != nil {
		return failure{70, "Rotation dispatcher inspection unavailable; guard retained."}
	}
	// Request the exact authorized execution and omit arguments, result and private errors.
	execution, err := client.Projects.Locations.Workflows.Executions.Get(intent.WorkflowExecution).
		Fields("state", "endTime", "workflowRevisionId").Context(ctx).Do()
	if err != nil || execution == nil || execution.WorkflowRevisionId != intent.WorkflowRevision {
		return failure{70, "Original rotation dispatcher identity unavailable; guard retained."}
	}
	if ended, err := time.Parse(time.RFC3339Nano, execution.EndTime); err != nil || ended.IsZero() {
		return failure{70, "Original rotation dispatcher has no verified end time; guard retained."}
	}
	switch execution.State {
	case "SUCCEEDED", "FAILED", "CANCELLED":
		return nil
	default:
		return failure{70, "Original rotation dispatcher is active or unknown; guard retained."}
	}
}
