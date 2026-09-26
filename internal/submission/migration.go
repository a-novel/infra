package submission

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"slices"
	"strings"
	"time"

	"cloud.google.com/go/deploy/apiv1/deploypb"
	"cloud.google.com/go/longrunning/autogen/longrunningpb"
	"cloud.google.com/go/run/apiv2/runpb"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/anypb"
)

// The envelope binds a native job snapshot to one immutable release identity.
// Configuration convergence and service-wide exclusion belong to the trusted caller.
type migrationIntent struct {
	SchemaVersion int             `json:"schemaVersion"`
	ReleaseUID    string          `json:"releaseUid"`
	Job           json.RawMessage `json:"job"`
}

func (scope scope) migrationImage(image string) bool {
	prefix := scope.Region + "-docker.pkg.dev/" + scope.ProjectID + "/agora-production/service-json-keys/jobs/migrations@sha256:"
	return strings.HasPrefix(image, prefix) && digestPattern.MatchString(strings.TrimPrefix(image, prefix))
}

func (scope scope) migrationIntent(id string) string {
	return strings.TrimSuffix(scope.intentName(id), ".json") + ".migration.json"
}

func (client cloud) migration(ctx context.Context, id string, output io.Writer) error {
	_, release, err := client.readRelease(ctx, id)
	if err != nil {
		return err
	}
	if release.Abandoned || release.RenderState != deploypb.Release_SUCCEEDED || release.Uid == "" {
		return errors.New("migration requires an identified, fully rendered, non-abandoned release")
	}
	name := client.scope.migrationIntent(id)
	if _, err := fmt.Fprintf(output, "Migration intent: gs://%s/%s\n", client.scope.ReceiptBucket, name); err != nil {
		return errors.New("cannot report migration intent identity")
	}
	job, operation, err := client.readMigration(ctx, name, release)
	if err != nil {
		return err
	}

	// Reconnect only to the recorded operation. The SDK owns polling; no execution
	// listing, latest-execution fallback or RunJob retry can enter this path.
	execution, err := client.jobs.RunJobOperation(operation.Name).Wait(ctx)
	if err != nil {
		return errors.New("migration wait interrupted or failed; inspect the recorded operation, never resubmit")
	}
	if err := completedMigration(job, operation, execution); err != nil {
		return err
	}
	_, _ = fmt.Fprintf(output, "Execution: %s\n", execution.Name)
	resultName := strings.TrimSuffix(name, ".json") + ".execution.json"
	// Publishing observed evidence is repeatable; dispatching database work is not.
	_ = client.create(ctx, resultName, execution)
	data, err := client.read(ctx, resultName)
	stored := &runpb.Execution{}
	if err != nil || protojson.Unmarshal(data, stored) != nil || !proto.Equal(stored, execution) {
		return errors.New("migration succeeded but exact execution evidence is unconfirmed; reconcile, do not rerun")
	}
	_, err = fmt.Fprintln(output, "Migration succeeded; exact execution evidence retained. Rollout and production success receipt remain separate obligations.")
	return err
}

func (client cloud) startMigration(ctx context.Context, id string, release *deploypb.Release, output io.Writer) error {
	job, err := client.jobs.GetJob(ctx, &runpb.GetJobRequest{Name: client.scope.location() + "/jobs/agora-json-keys-migrations"})
	if err != nil {
		return errors.New("exact migrations job unavailable")
	}
	if approved := client.approvedMigration; approved == nil || job.GetUid() != approved.Uid || !proto.Equal(job.GetTemplate(), approved.Template) {
		return errors.New("migrations configuration changed after operation admission")
	}
	if err := client.scope.checkMigrationJob(job, release); err != nil {
		return err
	}
	jobData, err := protojson.Marshal(job)
	if err != nil {
		return errors.New("cannot encode native migrations job")
	}
	data, err := json.Marshal(migrationIntent{SchemaVersion: 1, ReleaseUID: release.Uid, Job: jobData})
	if err != nil || len(data) > maxRequestBytes {
		return errors.New("cannot encode bounded migration intent")
	}
	name := client.scope.migrationIntent(id)
	if err := client.upload(ctx, name, data, "application/json"); err != nil {
		return errors.New("migration intent reservation not confirmed; no migration dispatched by this invocation")
	}
	// RunJob has no request-ID field and no retries in the pinned SDK. The etag
	// protects the inspected job version; the reservation prevents a second call.
	native, err := client.jobs.RunJob(ctx, &runpb.RunJobRequest{Name: job.Name, Etag: job.Etag})
	if err != nil {
		return errors.New("migration submission uncertain; retain intent and audit the job, never resubmit")
	}
	operation := &longrunningpb.Operation{Name: native.Name()}
	metadata, metadataErr := native.Metadata()
	if metadata != nil {
		operation.Metadata, metadataErr = anypb.New(metadata)
	}
	if err := client.recordOperation(ctx, name, operation, output); err != nil {
		return err
	}
	if metadataErr != nil {
		return errors.New("migration execution identity unreadable; inspect the recorded operation")
	}
	return nil
}

// Rollout submission consumes the saved success evidence without executing or
// waiting for database work. An incomplete migration cannot reserve a rollout.
func (client cloud) requireMigration(ctx context.Context, id string, release *deploypb.Release) error {
	name := client.scope.migrationIntent(id)
	job, operation, err := client.readMigration(ctx, name, release)
	if err != nil {
		return err
	}
	data, err := client.read(ctx, strings.TrimSuffix(name, ".json")+".execution.json")
	execution := &runpb.Execution{}
	if err != nil || protojson.Unmarshal(data, execution) != nil {
		return errors.New("successful migration evidence missing; reconcile before submitting a rollout")
	}
	return completedMigration(job, operation, execution)
}

func (client cloud) readMigration(ctx context.Context, name string, release *deploypb.Release) (*runpb.Job, *longrunningpb.Operation, error) {
	data, err := client.read(ctx, name)
	if err != nil {
		return nil, nil, err
	}
	var intent migrationIntent
	var trailing any
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&intent) != nil || decoder.Decode(&trailing) != io.EOF {
		return nil, nil, errors.New("invalid private migration intent")
	}
	job := &runpb.Job{}
	if intent.SchemaVersion != 1 || intent.ReleaseUID != release.Uid || protojson.Unmarshal(intent.Job, job) != nil {
		return nil, nil, errors.New("migration intent conflicts with the exact release identity")
	}
	if err := client.scope.checkMigrationJob(job, release); err != nil {
		return nil, nil, err
	}
	if approved := client.approvedMigration; approved != nil && (job.Uid != approved.Uid || !proto.Equal(job.Template, approved.Template)) {
		return nil, nil, errors.New("recorded migration differs from the approved operation job")
	}
	data, err = client.read(ctx, strings.TrimSuffix(name, ".json")+".operation.json")
	operation := &longrunningpb.Operation{}
	if err != nil || protojson.Unmarshal(data, operation) != nil || !client.scope.operation(operation.Name) {
		return nil, nil, errors.New("exact migration operation unavailable; manual audit required, never resubmit")
	}
	if !proto.Equal(operation, &longrunningpb.Operation{Name: operation.Name, Metadata: operation.Metadata}) {
		return nil, nil, errors.New("invalid migration operation record")
	}
	return job, operation, nil
}

func (scope scope) checkMigrationJob(job *runpb.Job, release *deploypb.Release) error {
	if job.GetName() != scope.location()+"/jobs/agora-json-keys-migrations" || !validRequestID(job.GetUid()) || job.GetEtag() == "" {
		return errors.New("migration job identity is incomplete or outside the selected service")
	}
	if job.Reconciling || job.DeleteTime != nil || job.Generation <= 0 || job.ObservedGeneration != job.Generation {
		return errors.New("migrations job is not converged")
	}
	if job.GetTerminalCondition().GetType() != "Ready" || job.GetTerminalCondition().GetState() != runpb.Condition_CONDITION_SUCCEEDED {
		return errors.New("migrations job is not ready")
	}
	template := job.GetTemplate().GetTemplate()
	if job.GetTemplate().GetTaskCount() != 1 || job.GetTemplate().GetParallelism() != 1 {
		return errors.New("migration requires exactly one task")
	}
	if template.GetRetries() == nil || template.GetMaxRetries() != 0 || template.GetTimeout().AsDuration() != 600*time.Second {
		return errors.New("migration requires explicit zero retries and the reviewed task timeout")
	}
	if template.GetServiceAccount() != release.DeployParameters["runtimeServiceAccount"] || len(template.GetContainers()) != 1 {
		return errors.New("migration runtime identity or container count differs from the selected service")
	}
	container := template.Containers[0]
	if container.Name != "migrations" || !scope.migrationImage(container.Image) || len(container.Command) != 0 || len(container.Args) != 0 {
		return errors.New("migration container must use the promoted image's unmodified entrypoint")
	}
	return nil
}

func completedMigration(job *runpb.Job, operation *longrunningpb.Operation, execution *runpb.Execution) error {
	prefix := job.Name + "/executions/"
	if !strings.HasPrefix(execution.GetName(), prefix) || !releasePattern.MatchString(strings.TrimPrefix(execution.GetName(), prefix)) {
		return errors.New("migration execution is outside the exact job")
	}
	if execution.Job != job.Name || !validRequestID(execution.Uid) || !proto.Equal(execution.Template, job.Template.Template) {
		return errors.New("migration execution identity or task configuration conflicts with the reserved job")
	}
	if operation.Metadata != nil {
		initial := &runpb.Execution{}
		if operation.Metadata.UnmarshalTo(initial) != nil {
			return errors.New("invalid migration operation metadata")
		}
		if (initial.Name != "" && initial.Name != execution.Name) || (initial.Uid != "" && initial.Uid != execution.Uid) {
			return errors.New("migration execution differs from the acknowledged operation")
		}
	}
	if execution.Reconciling || execution.DeleteTime != nil || execution.CompletionTime == nil || execution.CompletionTime.CheckValid() != nil {
		return errors.New("migration execution has no settled completion")
	}
	if execution.TaskCount != 1 || execution.Parallelism != 1 || execution.SucceededCount != 1 || execution.RunningCount != 0 {
		return errors.New("migration did not complete exactly one task successfully")
	}
	if execution.FailedCount != 0 || execution.CancelledCount != 0 || execution.RetriedCount != 0 {
		return errors.New("migration failed, was cancelled or retried; operator review required")
	}
	if !slices.ContainsFunc(execution.Conditions, func(condition *runpb.Condition) bool {
		return condition.GetType() == "Completed" && condition.GetState() == runpb.Condition_CONDITION_SUCCEEDED
	}) {
		return errors.New("migration completion condition is not successful")
	}
	return nil
}
