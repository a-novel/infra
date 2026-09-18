package rollout

import (
	"context"
	"errors"
	"fmt"
	"io"
	"time"

	deploy "cloud.google.com/go/deploy/apiv1"
	"cloud.google.com/go/deploy/apiv1/deploypb"
	"google.golang.org/api/option"
)

// Wait observes native progress within Timeout. Authentication and read retries belong
// to the official client; an interrupted observation never cancels the cloud rollout.
func (observer Observer) Wait(ctx context.Context, output io.Writer, options ...option.ClientOption) error {
	if !rolloutNamePattern.MatchString(observer.Name) {
		return errors.New("expected the exact rollout resource name with a numeric project")
	}
	if observer.Timeout <= 0 || observer.Timeout > 30*time.Minute {
		return errors.New("observation timeout must be positive and at most 30m")
	}
	if _, err := fmt.Fprintf(output, "## Cloud Deploy observation\n\nRollout: `%s`\n\n[Inspect this release and its rollouts](%s)\n\n", observer.Name, observer.consoleURL()); err != nil {
		return errors.New("cannot record rollout identity")
	}
	ctx, cancel := context.WithTimeout(ctx, observer.Timeout)
	defer cancel()
	client, err := deploy.NewCloudDeployRESTClient(ctx, options...)
	if err != nil {
		return reportObservation(output, Observation{"interrupted", "client initialization"})
	}
	defer func() { _ = client.Close() }() // No cloud operation is owned by this read-only client.
	var previous Observation
	for {
		observed := observer.read(ctx, client)
		if ctx.Err() != nil {
			observed = Observation{"interrupted", "observation timeout or cancellation"}
		}
		if observed != previous {
			if err := reportObservation(output, observed); err != nil {
				return err
			}
			previous = observed
		}
		if observed.Outcome == "succeeded" {
			return nil
		}
		select {
		case <-ctx.Done():
			return reportObservation(output, Observation{"interrupted", "observation timeout or cancellation"})
		case <-time.After(10 * time.Second):
		}
	}
}

func (observer Observer) read(ctx context.Context, client *deploy.CloudDeployClient) Observation {
	release, err := client.GetRelease(ctx, &deploypb.GetReleaseRequest{Name: observer.releaseName()})
	if err != nil {
		return Observation{"interrupted", "release status unavailable"}
	}
	var rollout *deploypb.Rollout
	if release.GetRenderState() == deploypb.Release_SUCCEEDED {
		rollout, err = client.GetRollout(ctx, &deploypb.GetRolloutRequest{Name: observer.Name})
		if err != nil {
			return Observation{"interrupted", "rollout status unavailable"}
		}
	}
	return observer.Check(release, rollout)
}

func reportObservation(output io.Writer, observed Observation) error {
	if _, err := fmt.Fprintf(output, "- %s: %s\n", observed.Outcome, observed.Stage); err != nil {
		return errors.New("cannot record rollout observation")
	}
	switch observed.Outcome {
	case "progress":
		return nil
	case "succeeded":
		_, err := fmt.Fprintln(output, "\nRollout verified. Durable recovery receipt publication remains a separate completion obligation.")
		return err
	default:
		_, _ = fmt.Fprintln(output, "\nInspect the linked rollout and follow [the observation runbook](https://github.com/a-novel/infra/blob/master/docs/runbooks/observe-rollout.md). Re-observe the same identity; do not replay migrations or resubmit a release.") // Best-effort recovery guidance after the verdict.
		return fmt.Errorf("cloud deploy observation %s at %s", observed.Outcome, observed.Stage)
	}
}
