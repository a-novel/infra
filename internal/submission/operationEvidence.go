package submission

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	jsonv2 "encoding/json/v2"
	"errors"
	"fmt"
	"io"
	"time"

	"cloud.google.com/go/deploy/apiv1/deploypb"
	"google.golang.org/api/option"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
)

type nativeGuard struct {
	SchemaVersion int             `json:"schemaVersion"`
	Kind          string          `json:"kind"`
	RunID         string          `json:"runId"`
	RunAttempt    string          `json:"runAttempt"`
	SHA256        string          `json:"sha256"`
	Configuration json.RawMessage `json:"configuration"`
}

type nativeCompletion struct {
	SchemaVersion int             `json:"schemaVersion"`
	Kind          string          `json:"kind"`
	Guard         int64           `json:"guardGeneration,string"`
	Configuration json.RawMessage `json:"configuration"`
	Release       json.RawMessage `json:"release"`
	Rollout       json.RawMessage `json:"rollout"`
	CompletedAt   string          `json:"completedAt"`
}

// OperationEvidence identifies the writer and historical outcome of a native release.
// It grants no authority to replay work. Only InspectOperation supplies the private
// configuration needed by the separately authorized completion finisher.
type OperationEvidence struct {
	RunID, RunAttempt, Commit string
	// Completed requires the exact generation-bound successful native record.
	Completed bool
	// Report contains only validated identifiers and the historical outcome.
	Report        string
	input         operationInputs
	configuration []byte
	generation    int64
}

// RecordCompletion proves and saves missing native success without changing cloud
// resources or deleting admission. The caller must independently authorize recovery
// and establish that the exact original workflow attempt has ended first.
func (evidence OperationEvidence) RecordCompletion(ctx context.Context, options ...option.ClientOption) error {
	if evidence.generation <= 0 || evidence.Completed {
		return errors.New("missing inspected native completion required")
	}
	return withOperation(ctx, evidence.input, evidence.configuration, options, func(operation serviceOperation) error {
		operation.generation = evidence.generation
		request, _ := operation.scope.request(operation.input.Request)
		_, err := operation.recordCompletion(ctx, request.ReleaseId)
		return err
	})
}

// InspectOperation validates historical native completion. read is confined to the
// approved receipt bucket, selects a generation before its bounded download, and
// returns nil only for absent metadata. No native APIs are invoked.
func InspectOperation(data []byte, generation int64, bucket, project string, getenv func(string) string, read func(string) ([]byte, error)) (*OperationEvidence, error) {
	invalid := errors.New("native operation evidence does not match the registered operation")
	var guard nativeGuard
	if jsonv2.Unmarshal(data, &guard, jsonv2.RejectUnknownMembers(true)) != nil || generation <= 0 ||
		guard.SchemaVersion != 1 || guard.Kind != "native-release" ||
		!numberPattern.MatchString(guard.RunID) || !numberPattern.MatchString(guard.RunAttempt) {
		return nil, invalid
	}
	if guard.SHA256 != fmt.Sprintf("%x", sha256.Sum256(guard.Configuration)) {
		return nil, invalid
	}
	input, request, err := registeredOperation(guard.Configuration, getenv, bucket)
	if err != nil || input.ProjectID != project {
		return nil, invalid
	}
	scope := input.scope()
	data, err = read(scope.prefix() + "native-success/" + request.ReleaseId + ".json")
	if err != nil {
		return nil, err
	}
	completion := "not recorded; native work may have been accepted or completed"
	if data != nil {
		if err := recordedNativeCompletion(data, guard.Configuration, generation, input, request); err != nil {
			return nil, err
		}
		completion = "recorded native success; exact configuration and rollout verified"
	}
	return &OperationEvidence{
		RunID: guard.RunID, RunAttempt: guard.RunAttempt, Commit: request.Release.Annotations["source-commit"],
		Completed: data != nil,
		input:     input, configuration: guard.Configuration, generation: generation,
		Report: fmt.Sprintf("Native release: %s; run %s-%s; commit %s\nRollout: %s/rollouts/production\nCompletion: %s\n",
			request.ReleaseId, guard.RunID, guard.RunAttempt, request.Release.Annotations["source-commit"], request.Release.Name, completion),
	}, nil
}

func recordedNativeCompletion(data, configuration []byte, generation int64, input operationInputs, request *deploypb.CreateReleaseRequest) error {
	invalid := errors.New("native completion does not establish the exact recorded successful rollout")
	var record nativeCompletion
	if jsonv2.Unmarshal(data, &record, jsonv2.RejectUnknownMembers(true)) != nil || record.SchemaVersion != 1 ||
		record.Kind != "native-release" || record.Guard != generation || !bytes.Equal(record.Configuration, configuration) {
		return invalid
	}
	completed, err := time.Parse(time.RFC3339Nano, record.CompletedAt)
	if err != nil || completed.IsZero() {
		return invalid
	}
	release, native := &deploypb.Release{}, &deploypb.Rollout{}
	if protojson.Unmarshal(record.Release, release) != nil || protojson.Unmarshal(record.Rollout, native) != nil ||
		release.Uid == "" || native.Uid == "" || !proto.Equal(request.Release, submittedFields(release)) {
		return invalid
	}
	if reportRollout(io.Discard, rolloutRequest(release, input.RolloutRequestID), release, native) != nil {
		return invalid
	}
	return nil
}
