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

	"github.com/a-novel/infra/internal/submission"
	"github.com/a-novel/infra/internal/workflow"
)

const inspectionLimit = 1 << 20

var digestPattern = regexp.MustCompile(`^[a-f0-9]{64}$`)

type operationEvidence struct {
	intent    applyIntent
	guard     objectReference
	live      int64
	completed bool
	native    *submission.OperationEvidence
}

func (custody store) inspectOperation(action string, args []string, getenv func(string) string, output io.Writer, options []option.ClientOption) error {
	confirmation := ""
	if action == "finish" {
		if len(args) != 3 {
			return failure{64, "Usage: infra custody operation finish <state-bucket> <registered-project> <guard-generation> <confirmation>"}
		}
		confirmation, args = args[2], args[:2]
	}
	if len(args) < 1 || len(args) > 2 {
		return failure{64, "Usage: infra custody operation inspect <state-bucket> <registered-project> [guard-generation]"}
	}
	scopes, err := workflow.ServiceScopes(getenv, custody.bucket)
	if err != nil || scopes["services/"+args[0]] == "" {
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
		project, err := workflow.FinishOperationProject([]string{scopes["services/"+args[0]], args[1], confirmation}, getenv)
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
	expected := applyIntent{Project: args[0], Service: scopes["services/"+args[0]], Region: region}
	evidence, err := readOperation(ctx, client, custody.bucket, expected, generation, getenv)
	if err != nil {
		return err
	}
	if action == "finish" {
		return custody.finishOperation(ctx, client, evidence, output)
	}
	return evidence.report(output)
}

// readOperation verifies historical evidence separately from the observed live guard.
func readOperation(ctx context.Context, client *storage.Service, bucket string, expected applyIntent, generation int64, getenv func(string) string) (operationEvidence, error) {
	guard := objectReference{Bucket: bucket, Name: "services/" + expected.Project + "/release/operation.json"}
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
	switch header.Kind {
	case "":
		evidence.intent, evidence.completed, err = inspectApply(ctx, client, expected, guard, data)
	case "native-release":
		evidence.native, err = submission.InspectOperation(data, generation, bucket, expected.Project, getenv, func(name string, selected int64) ([]byte, error) {
			receipts := strings.TrimSuffix(bucket, "-tofu-state") + "-deployment-receipts"
			if selected == 0 {
				var err error
				selected, err = liveGeneration(ctx, client, receipts, name)
				if err != nil || selected == 0 {
					return nil, err
				}
			}
			return readObject(ctx, client, objectReference{Bucket: receipts, Name: name, Generation: selected})
		})
		if err == nil {
			evidence.completed = evidence.native.Completed
		}
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

func inspectApply(ctx context.Context, client *storage.Service, expected applyIntent, guard objectReference, data []byte) (applyIntent, bool, error) {
	var intent applyIntent
	if err := decodeRecord(data, &intent); err != nil {
		return intent, false, err
	}
	if intent.SchemaVersion != 1 {
		return intent, false, failure{70, "Unsupported operation schema."}
	}
	if intent.Project != expected.Project || intent.Service != expected.Service || intent.Region != expected.Region {
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
	if evidence.native != nil {
		_, err := fmt.Fprintf(output, "Service: %s (%s)\nGuard generation: %d (%s)\n%sEvidence only: not current health, settled native work, a recovery receipt, or permission to unlock or retry.\n",
			evidence.intent.Service, evidence.intent.Project, evidence.guard.Generation, state, evidence.native.Report)
		return err
	}
	completion := "not recorded; apply may still have changed resources"
	if evidence.completed {
		completion = "recorded convergence; exact configuration verified"
	}
	intent := evidence.intent
	_, err := fmt.Fprintf(output, "Service: %s (%s)\nApply: %s; run %s-%s; plan %s; commit %s\nGuard generation: %d (%s)\nCompletion: %s\nEvidence only: not current health, settled native work, or permission to unlock or retry.\n",
		intent.Service, intent.Project, intent.Root, intent.RunID, intent.RunAttempt, intent.PlanID, intent.Commit, evidence.guard.Generation, state, completion)
	return err
}

func inspectCompletion(ctx context.Context, client *storage.Service, intent applyIntent, guard objectReference, configName string) (bool, error) {
	reference := objectReference{
		Bucket: strings.TrimSuffix(guard.Bucket, "-tofu-state") + "-deployment-receipts",
		Name:   fmt.Sprintf("services/%s/production/operations/%d.json", intent.Project, guard.Generation),
	}
	generation, err := liveGeneration(ctx, client, reference.Bucket, reference.Name)
	if err != nil {
		return false, err
	}
	if generation == 0 {
		return false, nil
	}
	reference.Generation = generation
	data, err := readObject(ctx, client, reference)
	if err != nil {
		return false, err
	}
	var completion applyCompletion
	if err := decodeRecord(data, &completion); err != nil {
		return false, err
	}
	expected := applyCompletion{1, "converged", intent, guard, objectReference{
		Bucket: guard.Bucket, Name: configName, Generation: completion.Configuration.Generation, SHA256: intent.InputsSHA256,
	}}
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
	return true, nil
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
