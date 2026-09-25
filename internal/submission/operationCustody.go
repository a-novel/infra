package submission

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strconv"
	"time"

	"cloud.google.com/go/deploy/apiv1/deploypb"
	cloudrun "cloud.google.com/go/run/apiv2"
	"cloud.google.com/go/run/apiv2/runpb"
	"google.golang.org/api/storage/v1"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
)

type serviceOperation struct {
	cloud
	input      operationInputs
	data       []byte
	services   *cloudrun.ServicesClient
	generation int64 // Only the acknowledgement from this invocation may set this.
}

func (operation serviceOperation) prefix() string {
	return "services/" + operation.input.ProjectID + "/release/"
}

func (operation *serviceOperation) acquire(ctx context.Context, getenv func(string) string, output io.Writer) error {
	name := operation.prefix() + "operation.json"
	if _, err := fmt.Fprintf(output, "Service guard: gs://%s/%s\n", operation.input.StateBucket, name); err != nil {
		return errors.New("cannot report operation identity")
	}
	guard := struct {
		SchemaVersion int             `json:"schemaVersion"`
		Kind          string          `json:"kind"`
		RunID         string          `json:"runId"`
		RunAttempt    string          `json:"runAttempt"`
		SHA256        string          `json:"sha256"`
		Configuration json.RawMessage `json:"configuration"`
	}{1, "native-release", getenv("GITHUB_RUN_ID"), getenv("GITHUB_RUN_ATTEMPT"), fmt.Sprintf("%x", sha256.Sum256(operation.data)), operation.data}
	object, err := operation.record(ctx, operation.input.StateBucket, name, guard)
	if err != nil {
		return errors.New("service admission busy or uncertain; no release or migration dispatched by this invocation")
	}
	operation.generation = object.Generation
	_, err = fmt.Fprintf(output, "Acquired guard generation: %d\n", object.Generation)
	return err
}

func (operation serviceOperation) held(ctx context.Context) error {
	if operation.generation <= 0 {
		return errors.New("this invocation has no acknowledged service guard")
	}
	object, err := operation.storage.Objects.Get(operation.input.StateBucket, operation.prefix()+"operation.json").
		IfGenerationMatch(operation.generation).Context(ctx).Do()
	if err != nil || object == nil || object.Generation != operation.generation {
		return errors.New("service guard no longer confirmed; manual reconciliation required")
	}
	return nil
}

func (operation serviceOperation) jobs(ctx context.Context) error {
	for _, role := range []string{"migrations", "rotatekeys"} {
		expected, _ := operation.input.job(role)
		job, err := operation.cloud.jobs.GetJob(ctx, &runpb.GetJobRequest{Name: expected.Name})
		if err != nil || job.GetUid() != expected.Uid || job.GetEtag() == "" || !proto.Equal(job.GetTemplate(), expected.Template) {
			return errors.New("native job identity or task configuration differs from approved HCL output")
		}
		if job.Reconciling || job.DeleteTime != nil || job.Generation <= 0 || job.Generation != job.ObservedGeneration ||
			job.GetTerminalCondition().GetState() != runpb.Condition_CONDITION_SUCCEEDED {
			return errors.New("native job configuration has not converged")
		}
	}
	return nil
}

// serving checks native success and actual traffic, not a newest-release listing.
// The selected predecessor keeps the same database/network/runtime boundary;
// expand/contract compatibility remains the service maintainer's responsibility.
func (operation serviceOperation) serving(ctx context.Context, id string) (*deploypb.Release, *deploypb.Rollout, error) {
	if err := operation.reconcileRollout(ctx, id, io.Discard); err != nil {
		return nil, nil, err
	}
	request, release, err := operation.readRelease(ctx, id)
	if err != nil {
		return nil, nil, err
	}
	native, err := operation.deploy.GetRollout(ctx, &deploypb.GetRolloutRequest{Name: release.Name + "/rollouts/production"})
	if err != nil || release.Uid == "" || native.GetUid() == "" {
		return nil, nil, errors.New("established rollout identity is unavailable")
	}
	expected := rolloutRequest(release, native.GetAnnotations()["request-id"])
	if !validRequestID(expected.RequestId) || expected.RequestId == request.RequestId || reportRollout(io.Discard, expected, release, native) != nil {
		return nil, nil, errors.New("exact rollout has not completed approved candidate and stable verification")
	}
	selected, _ := operation.scope.request(operation.input.Request)
	for _, key := range []string{"projectId", "network", "subnetwork", "runtimeServiceAccount", "databasePrivateIP", "managementProjectNumber"} {
		if release.DeployParameters[key] != selected.Release.DeployParameters[key] {
			return nil, nil, errors.New("native release changes the established database, network or runtime boundary")
		}
	}
	metadata := native.GetMetadata().GetCloudRun()
	name := operation.scope.location() + "/services/" + pilotTarget
	if metadata.GetService() != name || !releasePattern.MatchString(metadata.GetRevision()) {
		return nil, nil, errors.New("rollout does not identify the selected Cloud Run revision")
	}
	service, err := operation.services.GetService(ctx, &runpb.GetServiceRequest{Name: name})
	if err != nil || service.GetName() != name || service.GetUid() == "" || service.GetReconciling() || service.GetDeleteTime() != nil {
		return nil, nil, errors.New("serving service is not settled")
	}
	if service.Generation <= 0 || service.Generation != service.ObservedGeneration || service.GetTerminalCondition().GetState() != runpb.Condition_CONDITION_SUCCEEDED ||
		service.Ingress != runpb.IngressTraffic_INGRESS_TRAFFIC_INTERNAL_ONLY || service.InvokerIamDisabled {
		return nil, nil, errors.New("serving service readiness or private invocation differs from the pilot")
	}
	var total int32
	for _, traffic := range service.TrafficStatuses {
		if traffic.Percent < 0 || traffic.Percent > 100 || (traffic.Percent > 0 && traffic.Revision != metadata.Revision) {
			return nil, nil, errors.New("actual traffic differs from the selected verified revision")
		}
		total += traffic.Percent
	}
	if total != 100 {
		return nil, nil, errors.New("serving revision does not own all ordinary traffic")
	}
	return release, native, nil
}

func (operation serviceOperation) finish(ctx context.Context, id string, output io.Writer) error {
	if err := operation.held(ctx); err != nil {
		return err
	}
	if err := operation.jobs(ctx); err != nil {
		return err
	}
	release, native, err := operation.serving(ctx, id)
	if err != nil {
		return err
	}
	if err := operation.requireMigration(ctx, id, release); err != nil {
		return err
	}
	// Native records deliberately have a different namespace from legacy recovery
	// receipts. Their reader/cutover drill is a separate activation prerequisite.
	releaseJSON, err := protojson.Marshal(release)
	if err != nil {
		return errors.New("cannot encode completed native release")
	}
	rolloutJSON, err := protojson.Marshal(native)
	if err != nil {
		return errors.New("cannot encode completed native rollout")
	}
	receipt := struct {
		SchemaVersion int             `json:"schemaVersion"`
		Kind          string          `json:"kind"`
		Guard         int64           `json:"guardGeneration,string"`
		Configuration json.RawMessage `json:"configuration"`
		Release       json.RawMessage `json:"release"`
		Rollout       json.RawMessage `json:"rollout"`
		CompletedAt   string          `json:"completedAt"`
	}{1, "native-release", operation.generation, operation.data, releaseJSON, rolloutJSON, time.Now().UTC().Format(time.RFC3339)}
	object, err := operation.record(ctx, operation.scope.ReceiptBucket, operation.scope.prefix()+"native-success/"+id+".json", receipt)
	if err != nil {
		return errors.New("native rollout succeeded but completion publication is uncertain; guard retained")
	}
	completion := struct {
		SchemaVersion int    `json:"schemaVersion"`
		Kind          string `json:"kind"`
		Bucket        string `json:"bucket"`
		Object        string `json:"object"`
		Generation    int64  `json:"generation,string"`
	}{1, "native-release", object.Bucket, object.Name, object.Generation}
	if _, err := operation.record(ctx, operation.scope.ReceiptBucket, operation.scope.prefix()+"operations/"+strconv.FormatInt(operation.generation, 10)+".json", completion); err != nil {
		return errors.New("native completion breadcrumb unavailable; guard retained")
	}
	if err := operation.storage.Objects.Delete(operation.input.StateBucket, operation.prefix()+"operation.json").
		IfGenerationMatch(operation.generation).Context(ctx).Do(); err != nil {
		return errors.New("completion recorded but exact guard removal unconfirmed; inspect without replay")
	}
	_, err = fmt.Fprintf(output, "PASS native rollout and immutable completion: gs://%s/%s#%d\nService admission released. No legacy recovery receipt was created.\n", object.Bucket, object.Name, object.Generation)
	return err
}

func (operation serviceOperation) record(ctx context.Context, bucket, name string, value any) (*storage.Object, error) {
	data, err := json.Marshal(value)
	if err != nil {
		return nil, errors.New("cannot encode private operation evidence")
	}
	return operation.uploadTo(ctx, bucket, name, data, "application/json")
}
