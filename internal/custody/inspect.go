package custody

import (
	"bytes"
	"context"
	"encoding/json"
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

func (custody store) inspectOperation(args []string, getenv func(string) string, output io.Writer, options []option.ClientOption) error {
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
	ctx, cancel := context.WithTimeout(custody.ctx, time.Minute)
	defer cancel()
	client, err := storage.NewService(ctx, append(options, option.WithScopes(storage.DevstorageReadOnlyScope))...)
	if err != nil {
		return failure{70, "Operation inspection client unavailable."}
	}
	guard := objectReference{Bucket: custody.bucket, Name: "services/" + args[0] + "/release/operation.json"}
	live, err := liveGeneration(ctx, client, guard.Bucket, guard.Name)
	if err != nil {
		return err
	}
	if generation == 0 {
		generation = live
	}
	if generation == 0 {
		_, err = fmt.Fprintln(output, "No live service guard was observed; this does not establish any earlier apply outcome.")
		return err
	}
	guard.Generation = generation
	data, err := readObject(ctx, client, guard)
	if err != nil {
		return err
	}
	guard.SHA256 = checksum(data)
	var intent applyIntent
	if err := decodeRecord(data, &intent); err != nil {
		return err
	}
	if intent.SchemaVersion != 1 {
		return failure{70, "Unsupported operation schema."}
	}
	if intent.Project != args[0] || intent.Service != scopes["services/"+args[0]] || intent.Region != region {
		return failure{70, "Stored operation does not match the approved service scope."}
	}
	if !commitPattern.MatchString(intent.Commit) || !sequencePattern.MatchString(intent.PlanID) {
		return failure{70, "Stored operation identity is invalid."}
	}
	if !digestPattern.MatchString(intent.PlanSHA256) || !digestPattern.MatchString(intent.InputsSHA256) {
		return failure{70, "Stored operation hashes are invalid."}
	}
	name, err := intent.configurationName()
	if err != nil {
		return failure{70, "Stored operation root or run identity is invalid."}
	}
	completion, err := inspectCompletion(ctx, client, intent, guard, name)
	if err != nil {
		return err
	}
	// Two observations detect a change; they do not fence a still-running writer.
	current, err := liveGeneration(ctx, client, guard.Bucket, guard.Name)
	if err != nil {
		return err
	}
	if current != live {
		return failure{70, "Live guard changed during inspection; repeat only this read-only inspection."}
	}
	state := "another generation is live"
	switch live {
	case generation:
		state = "held"
	case 0:
		state = "no live guard"
	}
	_, err = fmt.Fprintf(output, "Service: %s (%s)\nApply: %s; run %s-%s; plan %s; commit %s\nGuard generation: %d (%s)\nCompletion: %s\nEvidence only: not current health, settled native work, or permission to unlock or retry.\n",
		intent.Service, intent.Project, intent.Root, intent.RunID, intent.RunAttempt, intent.PlanID, intent.Commit, generation, state, completion)
	return err
}

func inspectCompletion(ctx context.Context, client *storage.Service, intent applyIntent, guard objectReference, configName string) (string, error) {
	reference := objectReference{
		Bucket: strings.TrimSuffix(guard.Bucket, "-tofu-state") + "-deployment-receipts",
		Name:   fmt.Sprintf("services/%s/production/operations/%d.json", intent.Project, guard.Generation),
	}
	generation, err := liveGeneration(ctx, client, reference.Bucket, reference.Name)
	if err != nil {
		return "", err
	}
	if generation == 0 {
		return "not recorded; apply may still have changed resources", nil
	}
	reference.Generation = generation
	data, err := readObject(ctx, client, reference)
	if err != nil {
		return "", err
	}
	var completion applyCompletion
	if err := decodeRecord(data, &completion); err != nil {
		return "", err
	}
	expected := applyCompletion{1, "converged", intent, guard, objectReference{
		Bucket: guard.Bucket, Name: configName, Generation: completion.Configuration.Generation, SHA256: intent.InputsSHA256,
	}}
	if completion != expected || completion.Configuration.Generation <= 0 {
		return "", failure{70, "Completion evidence does not match the exact operation and configuration."}
	}
	data, err = readObject(ctx, client, completion.Configuration)
	if err != nil {
		return "", err
	}
	if checksum(data) != intent.InputsSHA256 {
		return "", failure{70, "Converged configuration integrity could not be verified."}
	}
	return "recorded convergence; exact configuration verified", nil
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
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if decoder.Decode(target) != nil || decoder.Decode(new(any)) != io.EOF {
		return failure{70, "Unsupported or malformed operation evidence."}
	}
	return nil
}
