package rollout_test

import (
	"testing"

	"cloud.google.com/go/deploy/apiv1/deploypb"
	"github.com/stretchr/testify/require"

	"github.com/a-novel/infra/internal/rollout"
)

func TestObserver(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name   string
		change func(*deploypb.Release, *deploypb.Rollout)
		want   rollout.Observation
	}{
		{
			name: "Success",
			want: rollout.Observation{"succeeded", "candidate and stable deployment/verification"},
		},
		{
			name: "Progress/Rendering",
			change: func(release *deploypb.Release, _ *deploypb.Rollout) {
				release.RenderState = deploypb.Release_IN_PROGRESS
			},
			want: rollout.Observation{"progress", "render"},
		},
		{
			name: "Error/Rendering",
			change: func(release *deploypb.Release, _ *deploypb.Rollout) {
				release.RenderState = deploypb.Release_FAILED
			},
			want: rollout.Observation{"failed", "render"},
		},
		{
			name: "Error/Abandoned",
			change: func(release *deploypb.Release, _ *deploypb.Rollout) {
				release.Abandoned = true
			},
			want: rollout.Observation{"failed", "release abandoned"},
		},
		{
			name: "Action/Approval",
			change: func(_ *deploypb.Release, value *deploypb.Rollout) {
				value.ApprovalState = deploypb.Rollout_NEEDS_APPROVAL
			},
			want: rollout.Observation{"action-required", "approval"},
		},
		{
			name: "Error/Rejected",
			change: func(_ *deploypb.Release, value *deploypb.Rollout) {
				value.ApprovalState = deploypb.Rollout_REJECTED
			},
			want: rollout.Observation{"failed", "approval rejected"},
		},
		{
			name: "Error/MissingApproval",
			change: func(_ *deploypb.Release, value *deploypb.Rollout) {
				value.ApprovalState = deploypb.Rollout_APPROVAL_STATE_UNSPECIFIED
			},
			want: rollout.Observation{"interrupted", "required approval not confirmed"},
		},
		{
			name: "Action/Advance",
			change: func(_ *deploypb.Release, value *deploypb.Rollout) {
				value.State = deploypb.Rollout_IN_PROGRESS
				value.Phases[1].State = deploypb.Phase_PENDING
			},
			want: rollout.Observation{"action-required", "advance stable"},
		},
		{
			name: "Progress/CandidatePending",
			change: func(_ *deploypb.Release, value *deploypb.Rollout) {
				value.State = deploypb.Rollout_IN_PROGRESS
				value.Phases[0].State = deploypb.Phase_PENDING
			},
			want: rollout.Observation{"progress", "canary-0 awaiting start"},
		},
		{
			name: "Progress/Queued",
			change: func(_ *deploypb.Release, value *deploypb.Rollout) {
				value.State = deploypb.Rollout_PENDING
			},
			want: rollout.Observation{"progress", "queued"},
		},
		{
			name: "Progress/Verification",
			change: func(_ *deploypb.Release, value *deploypb.Rollout) {
				value.State = deploypb.Rollout_IN_PROGRESS
				value.Phases[0].State = deploypb.Phase_IN_PROGRESS
				value.Phases[0].GetDeploymentJobs().VerifyJob.State = deploypb.Job_IN_PROGRESS
			},
			want: rollout.Observation{"progress", "canary-0/verify"},
		},
		{
			name: "Progress/PhaseFinalization",
			change: func(_ *deploypb.Release, value *deploypb.Rollout) {
				value.State = deploypb.Rollout_IN_PROGRESS
				value.Phases[1].State = deploypb.Phase_IN_PROGRESS
			},
			want: rollout.Observation{"progress", "stable finalization"},
		},
		{
			name: "Error/Candidate",
			change: func(_ *deploypb.Release, value *deploypb.Rollout) {
				value.State = deploypb.Rollout_FAILED
				value.Phases[0].GetDeploymentJobs().VerifyJob.State = deploypb.Job_FAILED
			},
			want: rollout.Observation{"failed", "canary-0/verify"},
		},
		{
			name: "Error/Stable",
			change: func(_ *deploypb.Release, value *deploypb.Rollout) {
				value.State = deploypb.Rollout_FAILED
				value.Phases[1].GetDeploymentJobs().VerifyJob.State = deploypb.Job_FAILED
			},
			want: rollout.Observation{"failed", "stable/verify"},
		},
		{
			name: "Error/Cancelled",
			change: func(_ *deploypb.Release, value *deploypb.Rollout) {
				value.State = deploypb.Rollout_CANCELLED
			},
			want: rollout.Observation{"failed", "cancelled"},
		},
		{
			name: "Action/Halted",
			change: func(_ *deploypb.Release, value *deploypb.Rollout) {
				value.State = deploypb.Rollout_HALTED
			},
			want: rollout.Observation{"action-required", "halted"},
		},
		{
			name: "Error/IgnoredVerification",
			change: func(_ *deploypb.Release, value *deploypb.Rollout) {
				value.Phases[1].GetDeploymentJobs().VerifyJob.State = deploypb.Job_IGNORED
			},
			want: rollout.Observation{"failed", "stable/verify did not succeed"},
		},
		{
			name: "Error/SkippedCandidate",
			change: func(_ *deploypb.Release, value *deploypb.Rollout) {
				value.Phases[0].State = deploypb.Phase_SKIPPED
			},
			want: rollout.Observation{"failed", "canary-0 did not run"},
		},
		{
			name: "Error/MissingVerification",
			change: func(_ *deploypb.Release, value *deploypb.Rollout) {
				value.Phases[1].GetDeploymentJobs().VerifyJob = nil
			},
			want: rollout.Observation{"interrupted", "stable/verify has no known state"},
		},
		{
			name: "Error/UnknownState",
			change: func(_ *deploypb.Release, value *deploypb.Rollout) {
				value.State = 999
			},
			want: rollout.Observation{"interrupted", "unknown rollout state"},
		},
		{
			name: "Error/WrongRelease",
			change: func(release *deploypb.Release, _ *deploypb.Rollout) {
				release.Name += "-other"
			},
			want: rollout.Observation{"interrupted", "release identity mismatch"},
		},
		{
			name: "Error/WrongRollout",
			change: func(_ *deploypb.Release, value *deploypb.Rollout) {
				value.Name += "-other"
			},
			want: rollout.Observation{"interrupted", "rollout or target identity mismatch"},
		},
		{
			name: "Error/WrongTarget",
			change: func(_ *deploypb.Release, value *deploypb.Rollout) {
				value.TargetId = "peer"
			},
			want: rollout.Observation{"interrupted", "rollout or target identity mismatch"},
		},
		{
			name: "Error/PhaseSet",
			change: func(_ *deploypb.Release, value *deploypb.Rollout) {
				value.Phases = value.Phases[1:]
			},
			want: rollout.Observation{"interrupted", "expected candidate and stable phases"},
		},
		{
			name: "Action/RolledBack",
			change: func(_ *deploypb.Release, value *deploypb.Rollout) {
				value.RolledBackByRollouts = []string{"other"}
			},
			want: rollout.Observation{"action-required", "rollout rolled back"},
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			_, state, _ := fixture(t)
			completeRollout(t, state.Rollout)
			observer := rollout.Observer{Name: state.Rollout.Name}
			if testCase.change != nil {
				testCase.change(state.Release, state.Rollout)
			}
			require.Equal(t, testCase.want, observer.Check(state.Release, state.Rollout))
		})
	}
}
