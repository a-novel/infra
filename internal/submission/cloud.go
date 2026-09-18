package submission

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"strings"

	deploy "cloud.google.com/go/deploy/apiv1"
	"cloud.google.com/go/deploy/apiv1/deploypb"
	"cloud.google.com/go/longrunning/autogen/longrunningpb"
	"google.golang.org/api/googleapi"
	"google.golang.org/api/storage/v1"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
)

type cloud struct {
	scope   scope
	deploy  *deploy.CloudDeployClient
	storage *storage.Service
}

func (client cloud) submit(ctx context.Context, request *deploypb.CreateReleaseRequest, output io.Writer) error {
	name := client.scope.intentName(request.ReleaseId)
	if err := client.create(ctx, name, request); err != nil {
		return errors.New("intent reservation not confirmed; no release dispatched by this invocation")
	}
	// CreateRelease has no automatic retries in the pinned SDK. An existing intent
	// never authorizes another call, even when the bytes or request UUID match.
	operation, err := client.deploy.CreateRelease(ctx, request)
	if err != nil {
		return errors.New("release submission uncertain; intent retained")
	}
	prefix := client.scope.location() + "/operations/"
	if !strings.HasPrefix(operation.Name(), prefix) || !validOperationID(strings.TrimPrefix(operation.Name(), prefix)) {
		return errors.New("release returned an unexpected operation identity; intent retained")
	}
	// Keep a log breadcrumb even if private operation recording fails. The immutable
	// record is still mandatory before waiting; console output cannot replace it.
	_, _ = fmt.Fprintf(output, "Operation: %s\n", operation.Name())
	if err := client.create(ctx, strings.TrimSuffix(name, ".json")+".operation.json", &longrunningpb.Operation{Name: operation.Name()}); err != nil {
		return errors.New("operation recording uncertain; release may already exist")
	}
	release, err := operation.Wait(ctx)
	if err != nil {
		return errors.New("release creation wait interrupted or failed; intent and operation retained")
	}
	return report(output, request, release)
}

func validOperationID(id string) bool {
	// Cloud Deploy operation IDs need not be UUIDs, but never contain path separators.
	return id != "" && len(id) <= 256 && strings.Trim(id, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_") == ""
}

func (client cloud) reconcile(ctx context.Context, id string, output io.Writer) error {
	response, err := client.storage.Objects.Get(client.scope.ReceiptBucket, client.scope.intentName(id)).Context(ctx).Download()
	if err != nil {
		return errors.New("exact private intent unavailable; do not resubmit")
	}
	defer func() { _ = response.Body.Close() }()
	data, err := io.ReadAll(io.LimitReader(response.Body, maxRequestBytes+1))
	if err != nil {
		return errors.New("cannot read exact private intent")
	}
	request, err := client.scope.request(data)
	if err != nil {
		return err
	}
	if request.ReleaseId != id {
		return errors.New("stored intent does not match the selected release")
	}
	release, err := client.deploy.GetRelease(ctx, &deploypb.GetReleaseRequest{Name: request.Release.Name})
	if err != nil {
		return errors.New("exact release unavailable; absence does not authorize resubmission")
	}
	return report(output, request, release)
}

func (client cloud) create(ctx context.Context, name string, message proto.Message) error {
	data, err := protojson.Marshal(message)
	if err != nil {
		return errors.New("cannot encode private submission record")
	}
	object, err := client.storage.Objects.Insert(client.scope.ReceiptBucket, &storage.Object{Name: name}).
		Media(bytes.NewReader(data), googleapi.ContentType("application/json"), googleapi.ChunkSize(0)).
		IfGenerationMatch(0).Context(ctx).Do()
	if err != nil {
		return errors.New("cannot confirm create-only submission record")
	}
	if object.Name != name || object.Bucket != client.scope.ReceiptBucket || object.Generation <= 0 {
		return errors.New("unexpected submission record identity")
	}
	return nil
}

func report(output io.Writer, request *deploypb.CreateReleaseRequest, release *deploypb.Release) error {
	if !proto.Equal(request.Release, submittedFields(release)) {
		return errors.New("native release conflicts with the reserved request")
	}
	if release.Abandoned {
		return errors.New("release is abandoned; operator review required")
	}
	var status string
	switch release.RenderState {
	case deploypb.Release_IN_PROGRESS:
		status = "rendering"
	case deploypb.Release_SUCCEEDED:
		status = "rendered"
	case deploypb.Release_FAILED:
		return errors.New("release render failed; inspect the exact release")
	default:
		return errors.New("release render state is not established")
	}
	_, err := fmt.Fprintf(output, "Release %s: %s. No rollout submitted; deployment and durable success receipt remain pending.\n", request.ReleaseId, status)
	return err
}
