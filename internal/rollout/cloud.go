package rollout

import (
	"context"
	"errors"
	"fmt"
	"io"
	"time"

	deploy "cloud.google.com/go/deploy/apiv1"
	"cloud.google.com/go/deploy/apiv1/deploypb"
	run "cloud.google.com/go/run/apiv2"
	"cloud.google.com/go/run/apiv2/runpb"
	"google.golang.org/api/option"
)

// Verify checks the exact native rollout and waits for one private probe execution.
// It never retries an ambiguous job submission or changes rollout state.
func Verify(ctx context.Context, config Config, output io.Writer, options ...option.ClientOption) error {
	ctx, cancel := context.WithTimeout(ctx, 8*time.Minute)
	defer cancel()
	deployClient, err := deploy.NewCloudDeployRESTClient(ctx, options...)
	if err != nil {
		return errors.New("cloud deploy client unavailable")
	}
	defer func() { _ = deployClient.Close() }()
	services, err := run.NewServicesRESTClient(ctx, options...)
	if err != nil {
		return errors.New("cloud run services client unavailable")
	}
	defer func() { _ = services.Close() }()
	revisions, err := run.NewRevisionsRESTClient(ctx, options...)
	if err != nil {
		return errors.New("cloud run revisions client unavailable")
	}
	defer func() { _ = revisions.Close() }()
	jobs, err := run.NewJobsRESTClient(ctx, options...)
	if err != nil {
		return errors.New("cloud run jobs client unavailable")
	}
	defer func() { _ = jobs.Close() }()

	inspect := func() (Probe, error) {
		var state Snapshot
		state.Release, err = deployClient.GetRelease(ctx, &deploypb.GetReleaseRequest{Name: config.releaseName()})
		if err != nil {
			return Probe{}, errors.New("release inspection failed")
		}
		state.Rollout, err = deployClient.GetRollout(ctx, &deploypb.GetRolloutRequest{Name: config.rolloutName()})
		if err != nil {
			return Probe{}, errors.New("rollout inspection failed")
		}
		state.JobRun, err = deployClient.GetJobRun(ctx, &deploypb.GetJobRunRequest{Name: config.jobRunName()})
		if err != nil {
			return Probe{}, errors.New("verification job inspection failed")
		}
		state.Service, err = services.GetService(ctx, &runpb.GetServiceRequest{Name: config.serviceName()})
		if err != nil {
			return Probe{}, errors.New("service inspection failed")
		}
		state.Revision, err = revisions.GetRevision(ctx, &runpb.GetRevisionRequest{Name: config.revisionName()})
		if err != nil {
			return Probe{}, errors.New("revision inspection failed")
		}
		return config.Check(state)
	}
	probe, err := inspect()
	if err != nil {
		return err
	}
	job, err := jobs.GetJob(ctx, &runpb.GetJobRequest{Name: config.probeName()})
	if err != nil {
		return errors.New("probe job inspection failed")
	}
	if err := config.CheckJob(job); err != nil {
		return err
	}
	request, err := probe.encode()
	if err != nil {
		return errors.New("probe request encoding failed")
	}
	// RunJob has no caller request ID. The SDK's RunJob default has no retry;
	// do not add one even though reading the resulting operation can be retried.
	operation, err := jobs.RunJob(ctx, &runpb.RunJobRequest{
		Name: config.probeName(), Etag: job.GetEtag(),
		Overrides: &runpb.RunJobRequest_Overrides{ContainerOverrides: []*runpb.RunJobRequest_Overrides_ContainerOverride{{
			Name: "probe", Env: []*runpb.EnvVar{{Name: "VERIFY_REQUEST", Values: &runpb.EnvVar_Value{Value: request}}},
		}}},
	})
	if err != nil {
		return errors.New("probe dispatch outcome unknown; reconcile Cloud Run executions before retrying verification")
	}
	if _, err := fmt.Fprintf(output, "Probe operation: %s; job run: %s\n", operation.Name(), config.jobRunName()); err != nil {
		return errors.New("probe operation accepted but its identifier could not be recorded")
	}
	execution, err := operation.Wait(ctx)
	if err != nil {
		return errors.New("probe did not confirm success; inspect the recorded operation before retrying verification")
	}
	if err := config.CheckExecution(execution, request); err != nil {
		return err
	}
	after, err := inspect()
	if err != nil {
		return err
	}
	if after != probe {
		return errors.New("verification target changed during the probe")
	}
	_, err = fmt.Fprintf(output, "PASS phase=%s revision=%s image=%s jobRun=%s execution=%s\n",
		probe.Phase, probe.Revision, probe.Image, probe.JobRun, execution.GetName())
	return err
}
