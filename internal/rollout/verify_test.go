package rollout_test

import (
	"encoding/json"
	"testing"
	"time"

	"cloud.google.com/go/deploy/apiv1/deploypb"
	"cloud.google.com/go/run/apiv2/runpb"
	"github.com/stretchr/testify/require"
	"google.golang.org/protobuf/types/known/timestamppb"

	"github.com/a-novel/infra/internal/rollout"
)

func TestConfig(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name   string
		change func(*rollout.Config, *rollout.Snapshot)
	}{
		{name: "Success/Candidate"},
		{name: "Success/Stable", change: func(config *rollout.Config, state *rollout.Snapshot) {
			config.Phase = "stable"
			state.JobRun.PhaseId = "stable"
			state.Service.TrafficStatuses = []*runpb.TrafficTargetStatus{{Revision: config.Revision, Percent: 100, Tag: "stable"}}
		}},
		{name: "Error/PeerProject", change: func(_ *rollout.Config, state *rollout.Snapshot) {
			state.Service.Name = "projects/peer/locations/europe-west1/services/agora-json-keys-grpc"
		}},
		{name: "Error/StaleTag", change: func(_ *rollout.Config, state *rollout.Snapshot) { state.Service.TrafficStatuses[1].Revision = "old" }},
		{name: "Error/ServingCandidate", change: func(_ *rollout.Config, state *rollout.Snapshot) {
			state.Service.TrafficStatuses[0].Percent = 99
			state.Service.TrafficStatuses[1].Percent = 1
		}},
		{name: "Error/WrongImage", change: func(_ *rollout.Config, state *rollout.Snapshot) { state.Revision.Containers[0].Image += "changed" }},
		{name: "Error/FloatingImage", change: func(_ *rollout.Config, state *rollout.Snapshot) {
			state.Release.BuildArtifacts[0].Tag = "service-json-keys:latest"
		}},
		{name: "Error/StalePhase", change: func(_ *rollout.Config, state *rollout.Snapshot) { state.JobRun.PhaseId = "stable" }},
		{name: "Error/Cancelled", change: func(_ *rollout.Config, state *rollout.Snapshot) { state.Rollout.State = deploypb.Rollout_CANCELLED }},
		{name: "Error/Unready", change: func(_ *rollout.Config, state *rollout.Snapshot) { state.Revision.Conditions = nil }},
		{name: "Error/PublicIngress", change: func(_ *rollout.Config, state *rollout.Snapshot) {
			state.Service.Ingress = runpb.IngressTraffic_INGRESS_TRAFFIC_ALL
		}},
		{name: "Error/Unreconciled", change: func(_ *rollout.Config, state *rollout.Snapshot) { state.Service.Generation++ }},
		{name: "Error/TokenDestination", change: func(_ *rollout.Config, state *rollout.Snapshot) {
			state.Service.TrafficStatuses[1].Uri = "https://other.run.app"
		}},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			config, state, _ := fixture(t)
			if testCase.change != nil {
				testCase.change(&config, &state)
			}
			probe, err := config.Check(state)
			if testCase.name[:5] == "Error" {
				require.Error(t, err)
				return
			}
			require.NoError(t, err)
			require.Equal(t, state.JobRun.Name, probe.JobRun)
			require.Equal(t, state.Revision.Name, probe.Revision)
			require.NoError(t, probe.Validate())
		})
	}
}

func TestConfigCheckExecution(t *testing.T) {
	t.Parallel()
	for _, testCase := range []struct {
		name   string
		change func(*runpb.Execution)
	}{
		{name: "Success"},
		{name: "Error/Unhealthy", change: func(execution *runpb.Execution) { execution.SucceededCount = 0; execution.FailedCount = 1 }},
		{name: "Error/Incomplete", change: func(execution *runpb.Execution) { execution.CompletionTime = nil }},
		{name: "Error/UnrelatedExecution", change: func(execution *runpb.Execution) { execution.Job = "unrelated" }},
		{name: "Error/StaleRequest", change: func(execution *runpb.Execution) {
			execution.Template.Containers[0].Env[0].Values = &runpb.EnvVar_Value{Value: "old"}
		}},
		{name: "Error/Secret", change: func(execution *runpb.Execution) {
			execution.Template.Containers[0].Env[0].Values = &runpb.EnvVar_ValueSource{ValueSource: &runpb.EnvVarSource{}}
		}},
		{name: "Error/PrivilegedIdentity", change: func(execution *runpb.Execution) { execution.Template.ServiceAccount = "application@example.com" }},
		{name: "Error/CommandOverride", change: func(execution *runpb.Execution) { execution.Template.Containers[0].Command = []string{"true"} }},
		{name: "Error/DatabaseNetworkTag", change: func(execution *runpb.Execution) {
			execution.Template.VpcAccess.NetworkInterfaces[0].Tags = []string{"agora-json-keys"}
		}},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()
			config, state, job := fixture(t)
			require.NoError(t, config.CheckJob(job))
			probe, err := config.Check(state)
			require.NoError(t, err)
			data, err := json.Marshal(probe)
			require.NoError(t, err)
			execution := &runpb.Execution{
				Name: job.Name + "/executions/probe-1", Job: job.Name, TaskCount: 1, SucceededCount: 1,
				CompletionTime: timestamppb.New(time.Unix(1, 0)), Template: job.Template.Template,
			}
			execution.Template.Containers[0].Env = []*runpb.EnvVar{{Name: "VERIFY_REQUEST", Values: &runpb.EnvVar_Value{Value: string(data)}}}
			if testCase.change != nil {
				testCase.change(execution)
			}
			err = config.CheckExecution(execution, string(data))
			if testCase.change != nil {
				require.Error(t, err)
			} else {
				require.NoError(t, err)
			}
		})
	}
}
