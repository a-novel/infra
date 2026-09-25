package custody

import (
	"context"
	"encoding/json"
	"regexp"
	"slices"
	"strings"

	"cloud.google.com/go/longrunning/autogen/longrunningpb"
	cloudrun "cloud.google.com/go/run/apiv2"
	"cloud.google.com/go/run/apiv2/runpb"
	"google.golang.org/api/option"
	"google.golang.org/api/storage/v1"
	"google.golang.org/protobuf/proto"
)

// rotationReservation is the dispatcher's pre-RunJob record of the inspected job.
type rotationReservation struct {
	Operation       rotationIntent `json:"operation"`
	GuardGeneration int64          `json:"guardGeneration,string"`
	Job             string         `json:"job"`
	JobUID          string         `json:"jobUID"`
	JobGeneration   int64          `json:"jobGeneration,string"`
	JobEtag         string         `json:"jobEtag"`
	Image           string         `json:"image"`
}

// rotationDispatch holds the acknowledged RunJob identity; execution fields can be absent.
type rotationDispatch struct {
	GuardGeneration int64  `json:"guardGeneration,string"`
	Operation       string `json:"operation"`
	Execution       string `json:"execution"`
	ExecutionUID    string `json:"executionUID"`
}

// recordCompletion observes only the reserved native operation. Its caller verifies
// that the original dispatcher ended before authorizing create-only evidence repair.
func (intent rotationIntent) recordCompletion(ctx context.Context, client *storage.Service, guard objectReference, options []option.ClientOption) error {
	bucket, prefix := intent.records(guard)
	var reservation rotationReservation
	var dispatch rotationDispatch
	for name, record := range map[string]any{"intent.json": &reservation, "operation.json": &dispatch} {
		data, err := readCurrentObject(ctx, client, bucket, prefix+name)
		if err != nil || data == nil {
			return failure{70, "Exact rotation reservation or acknowledgement unavailable; no work will be replayed."}
		}
		if err := decodeRecord(data, record); err != nil {
			return err
		}
	}
	if reservation.Operation != intent || reservation.GuardGeneration != guard.Generation || dispatch.GuardGeneration != guard.Generation {
		return failure{70, "Rotation dispatch records differ from the selected guard."}
	}
	jobs, err := cloudrun.NewJobsRESTClient(ctx, options...)
	if err != nil {
		return failure{70, "Rotation observation client unavailable."}
	}
	defer func() { _ = jobs.Close() }() // Best-effort read-only transport cleanup.
	// Resolve canonical project numbering through a request to the authorized project ID.
	jobName := "projects/" + intent.Project + "/locations/" + intent.Region + "/jobs/agora-json-keys-rotatekeys"
	job, err := jobs.GetJob(ctx, &runpb.GetJobRequest{Name: jobName})
	if err != nil || !reservation.matches(job) {
		return failure{70, "Reserved rotation job identity or configuration changed or is unavailable."}
	}
	location := strings.TrimSuffix(job.Name, "/jobs/agora-json-keys-rotatekeys")
	operationID, scoped := strings.CutPrefix(dispatch.Operation, location+"/operations/")
	if !scoped || !regexp.MustCompile(`^[a-zA-Z0-9-]{1,128}$`).MatchString(operationID) {
		return failure{70, "Recorded RunJob operation is outside the reserved job location."}
	}
	operation, err := jobs.GetOperation(ctx, &longrunningpb.GetOperationRequest{Name: dispatch.Operation})
	if err != nil || operation.GetName() != dispatch.Operation || !operation.GetDone() || operation.GetError() != nil {
		return failure{70, "Exact rotation operation is incomplete, failed or unavailable."}
	}
	execution := &runpb.Execution{}
	if operation.GetResponse().UnmarshalTo(execution) != nil || !dispatch.matches(execution, job) {
		return failure{70, "Native result does not prove the exact acknowledged rotation succeeded."}
	}
	completion := rotationCompletion{intent, guard.Generation, dispatch.Operation, execution.Name, execution.Uid, execution.CompletionTime.AsTime()}
	if err := intent.checkCompletion(completion, guard); err != nil {
		return err
	}
	data, err := json.Marshal(completion)
	if err != nil {
		return err
	}
	current, err := liveGeneration(ctx, client, guard.Bucket, guard.Name)
	if err != nil || current != guard.Generation {
		return failure{70, "Exact rotation guard is no longer held; completion repair blocked."}
	}
	_, err = createObject(ctx, client, bucket, prefix+"success.json", data)
	return err
}

// matches keeps reused job names and changed templates out of completion recovery.
func (reservation rotationReservation) matches(job *runpb.Job) bool {
	if job.GetName() != reservation.Job || job.GetUid() != reservation.JobUID || !rotationID.MatchString(reservation.JobUID) || reservation.JobEtag == "" {
		return false
	}
	if job.GetGeneration() != reservation.JobGeneration || reservation.JobGeneration <= 0 || job.GetObservedGeneration() != reservation.JobGeneration {
		return false
	}
	if job.Reconciling || job.DeleteTime != nil || job.GetTerminalCondition().GetState() != runpb.Condition_CONDITION_SUCCEEDED {
		return false
	}
	containers := job.GetTemplate().GetTemplate().GetContainers()
	prefix := reservation.Operation.Region + "-docker.pkg.dev/" + reservation.Operation.Project + "/agora-production/service-json-keys/jobs/rotatekeys@sha256:"
	return len(containers) == 1 && containers[0].Image == reservation.Image &&
		strings.HasPrefix(reservation.Image, prefix) && digestPattern.MatchString(strings.TrimPrefix(reservation.Image, prefix))
}

// matches accepts the same single-task success as the native dispatcher, including its retry policy.
func (dispatch rotationDispatch) matches(execution *runpb.Execution, job *runpb.Job) bool {
	if execution.Job != job.Name || !strings.HasPrefix(execution.Name, job.Name+"/executions/") || !rotationID.MatchString(execution.Uid) {
		return false
	}
	if (dispatch.Execution != "" && dispatch.Execution != execution.Name) || (dispatch.ExecutionUID != "" && dispatch.ExecutionUID != execution.Uid) {
		return false
	}
	if execution.Reconciling || execution.DeleteTime != nil || execution.CompletionTime == nil || execution.CompletionTime.CheckValid() != nil {
		return false
	}
	if execution.TaskCount != 1 || execution.Parallelism != 1 || execution.SucceededCount != 1 {
		return false
	}
	if execution.RunningCount != 0 || execution.FailedCount != 0 || execution.CancelledCount != 0 {
		return false
	}
	return proto.Equal(execution.Template, job.GetTemplate().GetTemplate()) && slices.ContainsFunc(execution.Conditions, func(condition *runpb.Condition) bool {
		return condition.GetType() == "Completed" && condition.GetState() == runpb.Condition_CONDITION_SUCCEEDED
	})
}
