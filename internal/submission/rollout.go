package submission

import (
	"context"
	"errors"
	"fmt"
	"io"

	"cloud.google.com/go/deploy/apiv1/deploypb"
	"cloud.google.com/go/longrunning/autogen/longrunningpb"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"

	"github.com/a-novel/infra/internal/rollout"
)

func (scope scope) rolloutIntent(id string) string {
	return scope.prefix() + "submissions/" + id + ".rollout.json"
}

// One fixed rollout per release keeps a changed UUID from opening another dispatch path.
func rolloutRequest(release *deploypb.Release, requestID string) *deploypb.CreateRolloutRequest {
	return &deploypb.CreateRolloutRequest{
		Parent: release.Name, RolloutId: "production", RequestId: requestID, StartingPhaseId: "canary-0",
		Rollout: &deploypb.Rollout{
			Name: release.Name + "/rollouts/production", TargetId: pilotTarget,
			Annotations: map[string]string{"request-id": requestID, "release-uid": release.Uid},
		},
	}
}

func (client cloud) submitRollout(ctx context.Context, id, requestID string, output io.Writer) error {
	releaseRequest, release, err := client.readRelease(ctx, id)
	if err != nil {
		return err
	}
	if release.Abandoned || release.RenderState != deploypb.Release_SUCCEEDED || release.Uid == "" {
		return errors.New("rollout requires an identified, fully rendered, non-abandoned release")
	}
	if err := client.requireMigration(ctx, id, release); err != nil {
		return err
	}
	if requestID == releaseRequest.RequestId {
		return errors.New("rollout request UUID must differ from the release request UUID")
	}
	if len(release.TargetSnapshots) != 1 || !client.scope.approvalTarget(release.TargetSnapshots[0]) {
		return errors.New("release must retain exactly the selected approval-required Cloud Run target")
	}
	target, err := client.deploy.GetTarget(ctx, &deploypb.GetTargetRequest{Name: release.TargetSnapshots[0].Name})
	if err != nil || !client.scope.approvalTarget(target) || target.GetUid() != release.TargetSnapshots[0].Uid {
		return errors.New("current target approval or identity no longer matches the release snapshot")
	}
	request := rolloutRequest(release, requestID)
	intent := client.scope.rolloutIntent(id)
	if err := client.create(ctx, intent, request); err != nil {
		return errors.New("rollout intent reservation not confirmed; no rollout dispatched by this invocation")
	}
	// The pinned SDK does not retry CreateRollout. Keep ambiguous outcomes reserved.
	operation, err := client.deploy.CreateRollout(ctx, request)
	if err != nil {
		return errors.New("rollout submission uncertain; intent retained")
	}
	if err := client.recordOperation(ctx, intent, &longrunningpb.Operation{Name: operation.Name()}, output); err != nil {
		return err
	}
	native, err := operation.Wait(ctx)
	if err != nil {
		return errors.New("rollout creation wait interrupted or failed; intent and operation retained")
	}
	return reportRollout(output, request, release, native)
}

func (scope scope) approvalTarget(target *deploypb.Target) bool {
	if target.GetName() != scope.location()+"/targets/"+pilotTarget || !target.GetRequireApproval() || target.GetUid() == "" {
		return false
	}
	location := target.GetRun().GetLocation()
	return location == scope.location() || location == "projects/"+scope.ProjectID+"/locations/"+scope.Region
}

func (client cloud) reconcileRollout(ctx context.Context, id string, output io.Writer) error {
	releaseRequest, release, err := client.readRelease(ctx, id)
	if err != nil {
		return err
	}
	data, err := client.read(ctx, client.scope.rolloutIntent(id))
	if err != nil {
		return err
	}
	request := &deploypb.CreateRolloutRequest{}
	if protojson.Unmarshal(data, request) != nil || !validRequestID(request.RequestId) {
		return errors.New("invalid private rollout intent")
	}
	if request.RequestId == releaseRequest.RequestId || release.Uid == "" || !proto.Equal(request, rolloutRequest(release, request.RequestId)) {
		return errors.New("rollout intent conflicts with the selected release identity or policy")
	}
	native, err := client.deploy.GetRollout(ctx, &deploypb.GetRolloutRequest{Name: request.Rollout.Name})
	if err != nil {
		return errors.New("exact rollout unavailable; absence does not authorize resubmission")
	}
	return reportRollout(output, request, release, native)
}

func reportRollout(output io.Writer, request *deploypb.CreateRolloutRequest, release *deploypb.Release, native *deploypb.Rollout) error {
	submitted := &deploypb.Rollout{Name: native.GetName(), TargetId: native.GetTargetId(), Annotations: native.GetAnnotations()}
	if !proto.Equal(request.Rollout, submitted) {
		return errors.New("native rollout conflicts with the reserved request")
	}
	observation := (rollout.Observer{Name: request.Rollout.Name}).Check(release, native)
	if _, err := fmt.Fprintf(output, "Rollout %s: %s (%s). Durable success receipt remains pending.\n", request.Rollout.Name, observation.Outcome, observation.Stage); err != nil {
		return errors.New("cannot report rollout state")
	}
	if observation.Outcome != "succeeded" {
		return errors.New("rollout completion not confirmed; inspect the same rollout before any further action")
	}
	return nil
}
