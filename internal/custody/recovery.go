package custody

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"time"

	"google.golang.org/api/option"
	"google.golang.org/api/storage/v1"

	"github.com/a-novel/infra/internal/recovery"
	"github.com/a-novel/infra/internal/workflow"
)

type restoreIntent struct {
	SchemaVersion int             `json:"schemaVersion"`
	Kind          string          `json:"kind"`
	Scope         string          `json:"scope,omitempty"`
	Target        recovery.Target `json:"target"`
	Preparation   objectReference `json:"preparation"`
	Commit        string          `json:"commit"`
	RunID         string          `json:"runId"`
	RunAttempt    string          `json:"runAttempt"`
}

type restoreCompletion struct {
	Outcome   string          `json:"outcome"`
	Operation restoreIntent   `json:"operation"`
	Guard     objectReference `json:"guard"`
	Attempt   objectReference `json:"attempt"`
	Evidence  objectReference `json:"evidence"`
}

func (custody store) restore(args []string, getenv func(string) string, output io.Writer, options []option.ClientOption) error {
	if len(args) != 3 {
		return failure{64, "Usage: infra custody recovery execute <state-bucket> <inputs-file> <preparation-generation> <confirmation>"}
	}
	if !workflow.RecoveryExecutionEnabled(getenv) || getenv("RECOVERY_OPERATION") != "restore-native" || getenv("GITHUB_REPOSITORY") != "a-novel/infra" {
		return failure{77, "Native file restoration is not activated in the protected recovery workflow."}
	}
	inputs, err := os.ReadFile(args[0])
	if err != nil {
		return err
	}
	host, err := workflow.RecoveryScope(inputs, getenv, custody.bucket)
	if err != nil {
		return failure{65, "Invalid native restore scope."}
	}
	source, err := recoverySource(host, getenv, custody.bucket)
	if err != nil {
		return err
	}
	if !workflow.RecoverySQLAllowed(host.VerifySQL, getenv) {
		return failure{77, "Offline SQL verification is not activated."}
	}
	generation, err := strconv.ParseInt(args[1], 10, 64)
	if err != nil || generation <= 0 || strconv.FormatInt(generation, 10) != args[1] || args[2] != host.Request().Confirmation(args[1]) {
		return failure{65, "Exact preparation generation and selected recovery confirmation are required."}
	}
	intent := restoreIntent{SchemaVersion: 1, Kind: "native-restore", Commit: getenv("GITHUB_SHA"), RunID: getenv("GITHUB_RUN_ID"), RunAttempt: getenv("GITHUB_RUN_ATTEMPT")}
	if source.Scope != "" {
		intent.SchemaVersion, intent.Scope = 2, source.Scope
	}
	if !commitPattern.MatchString(intent.Commit) || !sequencePattern.MatchString(intent.RunID+"-"+intent.RunAttempt) {
		return failure{65, "Invalid recovery workflow identity."}
	}
	ctx, cancel := context.WithTimeout(custody.ctx, 70*time.Minute)
	defer cancel()
	client, err := storage.NewService(ctx, options...)
	if err != nil {
		return err
	}
	prepared, err := readOperation(ctx, client, custody.bucket, source, generation, getenv)
	if err != nil {
		return err
	}
	if !prepared.completed || prepared.intent.Root != "service-recovery" || prepared.intent.Project != host.Project || prepared.intent.InputsSHA256 != checksum(inputs) {
		return failure{65, "Select completed host preparation with exactly these private inputs."}
	}
	if err := custody.completedWriter(ctx, prepared); err != nil {
		return err
	}
	intent.Preparation, err = currentReference(ctx, client, strings.TrimSuffix(custody.bucket, "-tofu-state")+"-deployment-receipts", source.completionName(generation))
	if err != nil {
		return err
	}
	preparation, target, err := preparedTarget(ctx, client, custody.bucket, source, intent.Preparation)
	if err != nil {
		return err
	}
	if preparation.Operation != prepared.intent || preparation.Guard != prepared.guard {
		return failure{65, "Preparation changed during inspection."}
	}
	intent.Target = target
	if intent.Target.Validate() != nil || intent.Target.Request != host.Request() || intent.Target.Zone != host.Zone {
		return failure{65, "Prepared resource identities differ from the approved recovery."}
	}
	encoded, err := json.Marshal(intent)
	if err != nil {
		return err
	}
	guard, err := createObject(ctx, client, custody.bucket, source.guardName(), encoded)
	if err != nil {
		return failure{70, "Native restore admission unconfirmed; do not retry or adopt an existing guard."}
	}
	if _, err := fmt.Fprintf(output, "Native file restoration guard: %s; generation %d. Inspect this generation after interruption; never replay.\n", host.SourceProject, guard.Generation); err != nil {
		return err
	}
	// Recheck state under source admission. Any uncertain mutation retains this guard.
	live, err := liveGeneration(ctx, client, preparation.State.Bucket, preparation.State.Name)
	if err != nil || live != preparation.State.Generation {
		return failure{70, "Prepared state changed; restore blocked and guard retained."}
	}
	attempt, err := createObject(ctx, client, custody.bucket, intent.attemptName(), encoded)
	if err != nil {
		return failure{70, "Destination reservation unconfirmed or already used; guard retained. Do not replay."}
	}
	runtime := recovery.Host{Target: intent.Target, DiskGiB: host.DiskGiB, Image: host.RestoreImage, Scratch: custody.scratch, Execute: custody.execute}
	files, err := runtime.Restore(ctx)
	if err != nil {
		return failure{70, "Selected recovery incomplete or uncertain; guard and destination retained. Inspect private host evidence without replay. " + err.Error()}
	}
	data, err := json.Marshal(files)
	if err != nil || len(data) > inspectionLimit {
		return failure{70, "Restore evidence exceeds custody limits; guard retained."}
	}
	evidence, err := createObject(ctx, client, custody.bucket, intent.evidenceName(), data)
	if err != nil {
		return failure{70, "Restore evidence publication unconfirmed; guard retained."}
	}
	data, err = json.Marshal(restoreCompletion{host.Request().Outcome(), intent, guard, attempt, evidence})
	if err != nil {
		return err
	}
	if _, err := createObject(ctx, client, intent.Preparation.Bucket, source.completionName(guard.Generation), data); err != nil {
		return failure{70, "Restore completion publication unconfirmed; guard retained."}
	}
	if err := client.Objects.Delete(guard.Bucket, guard.Name).IfGenerationMatch(guard.Generation).Context(ctx).Do(); err != nil {
		return failure{70, "Selected recovery completed and host stopped; guard removal unconfirmed. Finish only this recorded generation."}
	}
	_, err = fmt.Fprintf(output, "%s: private evidence recorded; host stopped. No cutover. Destination cannot be reused.\n", host.Request().Outcome())
	return err
}

func (intent restoreIntent) attemptName() string {
	return "foundation/recovery/services/" + intent.Target.Project + "/restore-attempt.json"
}

func (intent restoreIntent) evidenceName() string {
	return "foundation/recovery/services/" + intent.Target.Project + "/" + intent.Target.Request.Outcome() + ".json"
}

// recoverySource reuses the source service's admission and receipt paths for every recovery phase.
func recoverySource(host workflow.RecoveryHost, getenv func(string) string, bucket string) (applyIntent, error) {
	scope, err := host.SourceScope(getenv, bucket)
	if err != nil {
		return applyIntent{}, err
	}
	source := applyIntent{Project: host.SourceProject, Service: host.Request().Service, Region: host.Region}
	if strings.HasPrefix(scope, "workloads/") {
		source.Scope = scope
	}
	return source, nil
}

func currentReference(ctx context.Context, client *storage.Service, bucket, name string) (objectReference, error) {
	generation, err := liveGeneration(ctx, client, bucket, name)
	if err != nil || generation == 0 {
		return objectReference{}, failure{70, "Required private evidence is absent or unreadable."}
	}
	reference := objectReference{Bucket: bucket, Name: name, Generation: generation}
	data, err := readObject(ctx, client, reference)
	reference.SHA256 = checksum(data)
	return reference, err
}

func preparedTarget(ctx context.Context, client *storage.Service, bucket string, source applyIntent, ref objectReference) (applyCompletion, recovery.Target, error) {
	var preparation applyCompletion
	var target recovery.Target
	invalid := failure{65, "Preparation lacks matching resource-state evidence; prepare and review a new host."}
	if ref.Bucket != strings.TrimSuffix(bucket, "-tofu-state")+"-deployment-receipts" || ref.Generation <= 0 || !digestPattern.MatchString(ref.SHA256) {
		return preparation, target, invalid
	}
	data, err := readObject(ctx, client, ref)
	if err != nil || checksum(data) != ref.SHA256 || decodeRecord(data, &preparation) != nil || preparation.State == nil {
		return preparation, target, invalid
	}
	intent := preparation.Operation
	version := 1
	if source.Scope != "" {
		version = 2
	}
	if preparation.Guard.Bucket != bucket || preparation.Guard.Name != source.guardName() || preparation.Guard.Generation <= 0 {
		return preparation, target, invalid
	}
	if preparation.SchemaVersion != 1 || intent.SchemaVersion != version || preparation.Outcome != "host-prepared" || intent.Root != "service-recovery" || intent.SourceProject != source.Project || intent.Scope != source.Scope ||
		ref.Name != source.completionName(preparation.Guard.Generation) {
		return preparation, target, invalid
	}
	name, err := intent.configurationName()
	if err != nil {
		return preparation, target, invalid
	}
	if ok, err := inspectCompletion(ctx, client, intent, preparation.Guard, name); err != nil || !ok {
		return preparation, target, invalid
	}
	data, err = readObject(ctx, client, *preparation.State)
	var state struct {
		Outputs struct {
			Recovery struct {
				Value map[string]recovery.Target `json:"value"`
			} `json:"recovery"`
		} `json:"outputs"`
	}
	if err != nil || checksum(data) != preparation.State.SHA256 || json.Unmarshal(data, &state) != nil || len(state.Outputs.Recovery.Value) != 1 {
		return preparation, target, invalid
	}
	target = state.Outputs.Recovery.Value["selected"]
	if target.Validate() != nil || target.Project != intent.Project || target.Request.SourceProject != source.Project {
		return preparation, target, invalid
	}
	return preparation, target, nil
}

func inspectRestore(ctx context.Context, client *storage.Service, expected applyIntent, guard objectReference, data []byte, getenv func(string) string) (*restoreIntent, bool, error) {
	var intent restoreIntent
	if err := decodeRecord(data, &intent); err != nil {
		return nil, false, err
	}
	source, err := recoverySource(workflow.RecoveryHost{Service: intent.Target.Request.Service, SourceProject: intent.Target.Request.SourceProject, ManagementProject: intent.Target.Request.ManagementProject, Region: expected.Region}, getenv, guard.Bucket)
	version := 1
	if source.Scope != "" {
		version = 2
	}
	if err != nil || intent.SchemaVersion != version || intent.Scope != source.Scope || source.operationScope() != expected.operationScope() || source.guardName() != guard.Name ||
		intent.Kind != "native-restore" || intent.Target.Validate() != nil || intent.Target.Request.Service != expected.Service ||
		!commitPattern.MatchString(intent.Commit) || !sequencePattern.MatchString(intent.RunID+"-"+intent.RunAttempt) {
		return nil, false, failure{70, "Invalid native restore operation evidence."}
	}
	data, err = readCurrentObject(ctx, client, strings.TrimSuffix(guard.Bucket, "-tofu-state")+"-deployment-receipts", source.completionName(guard.Generation))
	if err != nil || data == nil {
		return &intent, false, err
	}
	var completed restoreCompletion
	if err := decodeRecord(data, &completed); err != nil {
		return nil, false, err
	}
	if completed.Operation != intent || completed.Guard != guard || completed.Outcome != intent.Target.Request.Outcome() ||
		completed.Attempt.Name != intent.attemptName() || completed.Evidence.Name != intent.evidenceName() {
		return nil, false, failure{70, "Restore completion differs from the admitted operation."}
	}
	_, target, err := preparedTarget(ctx, client, guard.Bucket, source, intent.Preparation)
	if err != nil || target != intent.Target {
		return nil, false, failure{70, "Restore completion differs from prepared resource identities."}
	}
	for _, ref := range []objectReference{completed.Attempt, completed.Evidence} {
		if ref.Bucket != guard.Bucket || ref.Generation <= 0 || !digestPattern.MatchString(ref.SHA256) {
			return nil, false, failure{70, "Invalid private restore reference."}
		}
		data, err := readObject(ctx, client, ref)
		if err != nil || checksum(data) != ref.SHA256 {
			return nil, false, failure{70, "Private restore evidence integrity failed."}
		}
		if ref == completed.Attempt {
			var reserved restoreIntent
			if decodeRecord(data, &reserved) != nil || reserved != intent {
				return nil, false, failure{70, "Restore reservation does not match completion."}
			}
		} else {
			var files map[string]string
			if decodeRecord(data, &files) != nil || intent.Target.Request.CheckEvidence(files) != nil {
				return nil, false, failure{70, "Selected recovery evidence is invalid."}
			}
		}
	}
	return &intent, true, nil
}
