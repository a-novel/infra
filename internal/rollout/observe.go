package rollout

import (
	"fmt"
	"regexp"
	"strings"
	"time"

	"cloud.google.com/go/deploy/apiv1/deploypb"
)

var rolloutNamePattern = regexp.MustCompile(`^projects/[1-9][0-9]*/locations/[a-z]+-[a-z]+[1-9][0-9]*/deliveryPipelines/[a-z]([a-z0-9-]{0,61}[a-z0-9])?/releases/[a-z]([a-z0-9-]{0,61}[a-z0-9])?/rollouts/[a-z]([a-z0-9-]{0,61}[a-z0-9])?$`)

// Observer follows one established-service rollout without changing cloud state.
// Name uses the project number and the pilot's identical pipeline/target IDs.
type Observer struct {
	Name    string
	Timeout time.Duration
}

// Observation is a payload-free verdict on rollout completion, not a recovery receipt.
type Observation struct {
	Outcome string
	Stage   string
}

// Check requires native success of both deployment and verification in each pilot phase.
func (observer Observer) Check(release *deploypb.Release, rollout *deploypb.Rollout) Observation {
	if !rolloutNamePattern.MatchString(observer.Name) {
		return Observation{"interrupted", "invalid rollout identity"}
	}
	if release.GetName() != observer.releaseName() {
		return Observation{"interrupted", "release identity mismatch"}
	}
	if release.GetAbandoned() {
		return Observation{"failed", "release abandoned"}
	}
	switch release.GetRenderState() {
	case deploypb.Release_FAILED:
		return Observation{"failed", "render"}
	case deploypb.Release_IN_PROGRESS:
		return Observation{"progress", "render"}
	case deploypb.Release_SUCCEEDED:
		// Rendering is complete; the rollout must still prove deployment and verification.
	default:
		return Observation{"interrupted", "unknown render state"}
	}
	if rollout.GetName() != observer.Name || rollout.GetTargetId() != strings.Split(observer.Name, "/")[5] {
		return Observation{"interrupted", "rollout or target identity mismatch"}
	}
	if len(rollout.GetRolledBackByRollouts()) != 0 {
		return Observation{"action-required", "rollout rolled back"}
	}
	switch rollout.GetApprovalState() {
	case deploypb.Rollout_REJECTED:
		return Observation{"failed", "approval rejected"}
	case deploypb.Rollout_NEEDS_APPROVAL:
		return Observation{"action-required", "approval"}
	case deploypb.Rollout_APPROVED:
		// The pilot requires explicit target approval before deployment.
	default:
		return Observation{"interrupted", "required approval not confirmed"}
	}
	switch rollout.GetState() {
	case deploypb.Rollout_PENDING_APPROVAL:
		return Observation{"action-required", "approval"}
	case deploypb.Rollout_APPROVAL_REJECTED, deploypb.Rollout_CANCELLED:
		return Observation{"failed", strings.ToLower(rollout.GetState().String())}
	case deploypb.Rollout_CANCELLING, deploypb.Rollout_HALTED:
		return Observation{"action-required", strings.ToLower(rollout.GetState().String())}
	case deploypb.Rollout_PENDING, deploypb.Rollout_PENDING_RELEASE:
		return Observation{"progress", "queued"}
	case deploypb.Rollout_FAILED:
		observed := checkPhases(rollout)
		if observed.Outcome == "failed" {
			return observed
		}
		return Observation{"failed", "rollout"}
	case deploypb.Rollout_IN_PROGRESS, deploypb.Rollout_SUCCEEDED:
		return checkPhases(rollout)
	default:
		return Observation{"interrupted", "unknown rollout state"}
	}
}

func checkPhases(rollout *deploypb.Rollout) Observation {
	if len(rollout.GetPhases()) != 2 {
		return Observation{"interrupted", "expected candidate and stable phases"}
	}
	for index, name := range []string{"canary-0", "stable"} {
		phase := rollout.GetPhases()[index]
		if phase.GetId() != name {
			return Observation{"interrupted", "unexpected phase identity"}
		}
		switch phase.GetState() {
		case deploypb.Phase_PENDING:
			if index == 0 {
				return Observation{"progress", name + " awaiting start"}
			}
			return Observation{"action-required", "advance " + name}
		case deploypb.Phase_SKIPPED, deploypb.Phase_ABORTED:
			return Observation{"failed", name + " did not run"}
		}
		jobs := phase.GetDeploymentJobs()
		for _, check := range []struct {
			name string
			job  *deploypb.Job
		}{
			{"deploy", jobs.GetDeployJob()},
			{"verify", jobs.GetVerifyJob()},
		} {
			stage := name + "/" + check.name
			switch check.job.GetState() {
			case deploypb.Job_FAILED, deploypb.Job_ABORTED:
				return Observation{"failed", stage}
			case deploypb.Job_DISABLED, deploypb.Job_SKIPPED, deploypb.Job_IGNORED:
				return Observation{"failed", stage + " did not succeed"}
			case deploypb.Job_PENDING, deploypb.Job_IN_PROGRESS:
				return Observation{"progress", stage}
			case deploypb.Job_SUCCEEDED:
				continue
			default:
				return Observation{"interrupted", stage + " has no known state"}
			}
		}
		switch phase.GetState() {
		case deploypb.Phase_SUCCEEDED:
			continue
		case deploypb.Phase_IN_PROGRESS:
			return Observation{"progress", name + " finalization"}
		default:
			return Observation{"interrupted", name + " did not complete"}
		}
	}
	if rollout.GetState() == deploypb.Rollout_SUCCEEDED {
		return Observation{"succeeded", "candidate and stable deployment/verification"}
	}
	return Observation{"progress", "rollout finalization"}
}

func (observer Observer) releaseName() string {
	name, _, _ := strings.Cut(observer.Name, "/rollouts/")
	return name
}

func (observer Observer) consoleURL() string {
	parts := strings.Split(observer.Name, "/")
	return fmt.Sprintf("https://console.cloud.google.com/deploy/delivery-pipelines/%s/%s/releases/%s?project=%s",
		parts[3], parts[5], parts[7], parts[1])
}
