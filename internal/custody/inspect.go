package custody

import (
	"context"
	"encoding/json"
	jsonv2 "encoding/json/v2"
	"errors"
	"fmt"
	"io"
	"regexp"
	"strconv"
	"strings"
	"time"

	"google.golang.org/api/googleapi"
	"google.golang.org/api/option"
	"google.golang.org/api/storage/v1"

	"github.com/a-novel/infra/internal/workflow"
)

const inspectionLimit = 1 << 20

var digestPattern = regexp.MustCompile(`^[a-f0-9]{64}$`)

type operationEvidence struct {
	intent    applyIntent
	guard     objectReference
	live      int64
	completed bool
	rotation  *rotationIntent
	restore   *restoreIntent
	cleanup   *cleanupIntent
}

func (custody store) inspectOperation(action string, args []string, getenv func(string) string, output io.Writer, options []option.ClientOption) error {
	confirmation := ""
	if action == "finish" {
		if len(args) != 3 {
			return failure{64, "Usage: infra custody operation finish <state-bucket> <registered-operation-scope> <guard-generation> <confirmation>"}
		}
		confirmation, args = args[2], args[:2]
	}
	if len(args) < 1 || len(args) > 2 {
		return failure{64, "Usage: infra custody operation inspect <state-bucket> <registered-operation-scope> [guard-generation]"}
	}
	scopes, err := workflow.OperationScopes(getenv, custody.bucket)
	if err != nil || scopes[args[0]] == "" {
		return failure{65, "Operation inspection does not match protected registration."}
	}
	var registration map[string]json.RawMessage
	if err := json.Unmarshal([]byte(getenv("FOUNDATION_CONFIG")), &registration); err != nil {
		return err
	}
	var region string
	if err := json.Unmarshal(registration["region"], &region); err != nil {
		return err
	}
	var generation int64
	if len(args) == 2 {
		generation, err = strconv.ParseInt(args[1], 10, 64)
		if err != nil || generation <= 0 || strconv.FormatInt(generation, 10) != args[1] {
			return failure{64, "Expected a positive guard generation."}
		}
	}
	readScope := storage.DevstorageReadOnlyScope
	if action == "finish" {
		project, err := workflow.FinishOperationProject([]string{scopes[args[0]], args[1], confirmation}, getenv)
		if err != nil || project != args[0] {
			return failure{65, "Finishing a recorded operation requires exact protected recovery authorization."}
		}
		readScope = storage.DevstorageReadWriteScope
	}
	ctx, cancel := context.WithTimeout(custody.ctx, time.Minute)
	defer cancel()
	client, err := storage.NewService(ctx, append(options, option.WithScopes(readScope))...)
	if err != nil {
		return failure{70, "Operation inspection client unavailable."}
	}
	expected := applyIntent{Project: args[0], Service: scopes[args[0]], Region: region}
	if strings.HasPrefix(args[0], "workloads/") {
		expected.Project, expected.Scope = "", args[0]
	}
	evidence, err := readOperation(ctx, client, custody.bucket, expected, generation, getenv)
	if err != nil {
		return err
	}
	if action == "finish" {
		return custody.finishOperation(ctx, client, evidence, output, options)
	}
	return evidence.report(output)
}

// readOperation verifies historical evidence separately from the observed live guard.
func readOperation(ctx context.Context, client *storage.Service, bucket string, expected applyIntent, generation int64, getenv func(string) string) (operationEvidence, error) {
	guard := objectReference{Bucket: bucket, Name: expected.guardName()}
	live, err := liveGeneration(ctx, client, guard.Bucket, guard.Name)
	if err != nil {
		return operationEvidence{}, err
	}
	if generation == 0 {
		generation = live
	}
	if generation == 0 {
		return operationEvidence{}, nil
	}
	guard.Generation = generation
	data, err := readObject(ctx, client, guard)
	if err != nil {
		return operationEvidence{}, err
	}
	guard.SHA256 = checksum(data)
	evidence := operationEvidence{intent: expected, guard: guard, live: live}
	var header struct {
		Kind string `json:"kind"`
	}
	if jsonv2.Unmarshal(data, &header) != nil {
		return operationEvidence{}, failure{70, "Malformed operation evidence."}
	}
	if expected.Scope != "" && header.Kind != "" {
		return operationEvidence{}, failure{70, "Shared runtime operations are not enrolled."}
	}
	switch header.Kind {
	case "":
		evidence.intent, evidence.completed, err = inspectApply(ctx, client, expected, guard, data, getenv)
	case "scheduled-rotation":
		evidence.rotation, evidence.completed, err = inspectRotation(ctx, client, expected, guard, data)
	case "native-restore":
		evidence.restore, evidence.completed, err = inspectRestore(ctx, client, expected, guard, data)
	case "native-cleanup":
		evidence.cleanup, evidence.completed, err = inspectCleanup(ctx, client, expected, guard, data)
	default:
		err = failure{70, "Unsupported operation kind; retain the guard for protected reconciliation."}
	}
	if err != nil {
		return operationEvidence{}, err
	}
	// Two observations detect a change; they do not fence a still-running writer.
	current, err := liveGeneration(ctx, client, guard.Bucket, guard.Name)
	if err != nil {
		return operationEvidence{}, err
	}
	if current != live {
		return operationEvidence{}, failure{70, "Live guard changed during inspection; repeat only this read-only inspection."}
	}
	return evidence, nil
}

func inspectApply(ctx context.Context, client *storage.Service, expected applyIntent, guard objectReference, data []byte, getenv func(string) string) (applyIntent, bool, error) {
	var intent applyIntent
	if err := decodeRecord(data, &intent); err != nil {
		return intent, false, err
	}
	if expected.Scope != "" {
		scopes, err := workflow.ReleaseScopes(getenv, guard.Bucket)
		parts := strings.Split(intent.Scope, "/")
		if err != nil || intent.SchemaVersion != 2 || (intent.Root != "service-foundation" && intent.Root != "service-release") ||
			!foundationScopePattern.MatchString(intent.Scope) || scopes[intent.Scope] != intent.Service ||
			len(parts) != 5 || parts[3] != intent.Project || parts[4] != intent.Service {
			return intent, false, failure{70, "Shared operation does not match registered prerequisites."}
		}
	} else if intent.SchemaVersion != 1 || intent.Scope != "" {
		return intent, false, failure{70, "Unsupported operation schema."}
	}
	if intent.operationScope() != expected.operationScope() || intent.Service != expected.Service || intent.Region != expected.Region ||
		(intent.Root != "service-recovery" && intent.SourceProject != "") {
		return intent, false, failure{70, "Stored operation does not match the approved service scope."}
	}
	if !commitPattern.MatchString(intent.Commit) || !sequencePattern.MatchString(intent.PlanID) {
		return intent, false, failure{70, "Stored operation identity is invalid."}
	}
	if !digestPattern.MatchString(intent.PlanSHA256) || !digestPattern.MatchString(intent.InputsSHA256) {
		return intent, false, failure{70, "Stored operation hashes are invalid."}
	}
	name, err := intent.configurationName()
	if err != nil {
		return intent, false, failure{70, "Stored operation root or run identity is invalid."}
	}
	completion, err := inspectCompletion(ctx, client, intent, guard, name)
	return intent, completion, err
}

func (evidence operationEvidence) report(output io.Writer) error {
	if evidence.guard.Generation == 0 {
		_, err := fmt.Fprintln(output, "No live service guard was observed; this does not establish any earlier operation outcome.")
		return err
	}
	state := "another generation is live"
	switch evidence.live {
	case evidence.guard.Generation:
		state = "held"
	case 0:
		state = "no live guard"
	}
	if evidence.rotation != nil {
		completion := "not recorded; rotation may still have run"
		if evidence.completed {
			completion = "recorded successful rotation"
		}
		_, err := fmt.Fprintf(output, "Service: %s (%s)\nGuard generation: %d (%s)\nRotation: %s; revision %s\nCompletion: %s\nEvidence only: not current health, a settled dispatcher, or permission to unlock or retry.\n",
			evidence.intent.Service, evidence.intent.Project, evidence.guard.Generation, state,
			evidence.rotation.WorkflowExecution, evidence.rotation.WorkflowRevision, completion)
		return err
	}
	if evidence.restore != nil {
		completion := "not recorded; host work may still be running"
		if evidence.completed {
			completion = "files restored and host stopped; PostgreSQL not started or verified"
			if evidence.restore.Target.Request.VerifySQL {
				completion = "SQL verified offline at backup consistency; PostgreSQL and host stopped"
			}
		}
		_, err := fmt.Fprintf(output, "Service: %s (%s)\nGuard generation: %d (%s)\nNative restoration: %s\nCompletion: %s\nNever replay this destination. Evidence is not current health, source fencing, cutover or permission to unlock.\n",
			evidence.intent.Service, evidence.intent.Project, evidence.guard.Generation, state, evidence.restore.Target.Project, completion)
		return err
	}
	if evidence.cleanup != nil {
		completion := "not recorded; inspect project lifecycle without replaying deletion"
		if evidence.completed {
			completion = "deletion-requested; not permanent erasure or final billing reconciliation"
		}
		_, err := fmt.Fprintf(output, "Service: %s (%s)\nGuard generation: %d (%s)\nCleanup: %s (%s)\nCompletion: %s\nManagement evidence and reservations remain retained. Never reuse this destination.\n",
			evidence.intent.Service, evidence.intent.Project, evidence.guard.Generation, state, evidence.cleanup.Target.Project, evidence.cleanup.Target.Number, completion)
		return err
	}
	completion := "not recorded; apply may still have changed resources"
	if evidence.completed {
		completion = "recorded convergence; exact configuration verified"
		if evidence.intent.Root == "service-recovery" {
			completion = "host prepared; exact configuration verified; no database recovery or cutover"
		}
	}
	intent := evidence.intent
	_, err := fmt.Fprintf(output, "Service: %s (%s)\nApply: %s; run %s-%s; plan %s; commit %s\nGuard generation: %d (%s)\nCompletion: %s\nEvidence only: not current health, settled native work, or permission to unlock or retry.\n",
		intent.Service, intent.guardProject(), intent.Root+"/"+intent.Project, intent.RunID, intent.RunAttempt, intent.PlanID, intent.Commit, evidence.guard.Generation, state, completion)
	return err
}

func inspectCompletion(ctx context.Context, client *storage.Service, intent applyIntent, guard objectReference, configName string) (bool, error) {
	reference := objectReference{
		Bucket: strings.TrimSuffix(guard.Bucket, "-tofu-state") + "-deployment-receipts",
		Name:   intent.completionName(guard.Generation),
	}
	data, err := readCurrentObject(ctx, client, reference.Bucket, reference.Name)
	if err != nil || data == nil {
		return false, err
	}
	var completion applyCompletion
	if err := decodeRecord(data, &completion); err != nil {
		return false, err
	}
	expected := applyCompletion{SchemaVersion: 1, Outcome: intent.outcome(), Operation: intent, Guard: guard, Configuration: objectReference{
		Bucket: guard.Bucket, Name: configName, Generation: completion.Configuration.Generation, SHA256: intent.InputsSHA256,
	}, State: completion.State, Checks: completion.Checks}
	if completion != expected || completion.Configuration.Generation <= 0 {
		return false, failure{70, "Completion evidence does not match the exact operation and configuration."}
	}
	data, err = readObject(ctx, client, completion.Configuration)
	if err != nil {
		return false, err
	}
	if checksum(data) != intent.InputsSHA256 {
		return false, failure{70, "Converged configuration integrity could not be verified."}
	}
	if completion.State != nil {
		state := *completion.State
		if intent.Root != "service-recovery" || state.Bucket != guard.Bucket ||
			state.Name != "foundation/recovery/services/"+intent.Project+"/default.tfstate" ||
			state.Generation <= 0 || !digestPattern.MatchString(state.SHA256) {
			return false, failure{70, "Prepared recovery state reference is invalid."}
		}
		data, err := readObject(ctx, client, state)
		if err != nil || checksum(data) != state.SHA256 {
			return false, failure{70, "Prepared recovery state integrity could not be verified."}
		}
	}
	return true, nil
}

func readCurrentObject(ctx context.Context, client *storage.Service, bucket, name string) ([]byte, error) {
	generation, err := liveGeneration(ctx, client, bucket, name)
	if err != nil || generation == 0 {
		return nil, err
	}
	return readObject(ctx, client, objectReference{Bucket: bucket, Name: name, Generation: generation})
}

// Only metadata 404 means absent. A failed pinned download is never absence evidence.
func liveGeneration(ctx context.Context, client *storage.Service, bucket, name string) (int64, error) {
	object, err := client.Objects.Get(bucket, name).Context(ctx).Do()
	var remote *googleapi.Error
	if errors.As(err, &remote) && remote.Code == 404 {
		return 0, nil
	}
	if err != nil || object == nil || object.Bucket != bucket || object.Name != name || object.Generation <= 0 {
		return 0, failure{70, "Private operation metadata could not be verified."}
	}
	return object.Generation, nil
}

func readObject(ctx context.Context, client *storage.Service, reference objectReference) ([]byte, error) {
	response, err := client.Objects.Get(reference.Bucket, reference.Name).Generation(reference.Generation).Context(ctx).Download()
	if err != nil {
		return nil, failure{70, "Exact private operation evidence could not be read."}
	}
	defer func() { _ = response.Body.Close() }() // Best-effort read-only transport cleanup.
	data, err := io.ReadAll(io.LimitReader(response.Body, inspectionLimit+1))
	if err != nil || len(data) > inspectionLimit {
		return nil, failure{70, "Private operation evidence is unreadable or oversized."}
	}
	return data, nil
}

func decodeRecord(data []byte, target any) error {
	if jsonv2.Unmarshal(data, target, jsonv2.RejectUnknownMembers(true)) != nil {
		return failure{70, "Unsupported or malformed operation evidence."}
	}
	return nil
}
